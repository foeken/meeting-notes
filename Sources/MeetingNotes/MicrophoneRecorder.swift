@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

final class MicrophoneRecorder: @unchecked Sendable {
  var onSamples: (@Sendable ([Int16]) -> Void)? {
    get { lock.withLock { samplesHandler } }
    set { lock.withLock { samplesHandler = newValue } }
  }

  /// Like `onSamples`, but also delivers the WAV sample position (including
  /// alignment padding) after these samples were written. Live transcription
  /// can use it to keep timestamps on the capture clock across pause/resume.
  var onSamplesAtPosition: (@Sendable ([Int16], Int) -> Void)? {
    get { lock.withLock { positionHandler } }
    set { lock.withLock { positionHandler = newValue } }
  }

  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var samplesHandler: (@Sendable ([Int16]) -> Void)?
  private var positionHandler: (@Sendable ([Int16], Int) -> Void)?
  private var handle: FileHandle?
  private var byteCount = 0
  private var outputURL: URL?
  private var tapping = false
  private var alignmentClock: CaptureClock?
  private var needsAlignment = false
  private var bytesSinceCheckpoint = 0
  private var writeError: Error?
  private var preferredDeviceUID: String?

  func usePreferredDevice(_ uid: String?) {
    lock.withLock { preferredDeviceUID = uid }
  }

  func start(writingTo url: URL, clock: CaptureClock) throws {
    let created = try WavFile.create(at: url)
    lock.withLock {
      handle = created
      outputURL = url
      byteCount = 0
      bytesSinceCheckpoint = 0
      writeError = nil
      alignmentClock = clock
      needsAlignment = true
    }
    do { try startEngine() } catch {
      lock.withLock {
        try? handle?.close()
        handle = nil
        outputURL = nil
        alignmentClock = nil
      }
      throw error
    }
  }

  func pause() {
    guard lock.withLock({ tapping }) else { return }
    engine.inputNode.removeTap(onBus: 0)
    lock.withLock { tapping = false }
    engine.stop()
    lock.lock()
    if let handle {
      do { try WavFile.checkpoint(handle, bytes: byteCount) } catch { writeError = error }
    }
    lock.unlock()
  }

  func resume() throws {
    let canResume = lock.withLock { () -> Bool in
      guard handle != nil, !tapping else { return false }
      needsAlignment = true
      return true
    }
    guard canResume else { return }
    try startEngine()
  }

  private func startEngine() throws {
    let input = engine.inputNode
    if let preferredDeviceUID = lock.withLock({ preferredDeviceUID }) {
      guard let deviceID = MicrophoneDeviceProvider.audioDeviceID(forUID: preferredDeviceUID),
        let audioUnit = input.audioUnit
      else {
        throw NSError(
          domain: "MicrophoneRecorder", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The preferred microphone is unavailable"])
      }
      var selectedDevice = deviceID
      let status = AudioUnitSetProperty(
        audioUnit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0,
        &selectedDevice, UInt32(MemoryLayout<AudioDeviceID>.size)
      )
      guard status == noErr else {
        throw NSError(
          domain: "MicrophoneRecorder", code: Int(status),
          userInfo: [NSLocalizedDescriptionKey: "The preferred microphone could not be selected"])
      }
    }
    // AVAudioEngine can retain the previous/default device's sample rate after
    // kAudioOutputUnitProperty_CurrentDevice changes. This is particularly
    // visible with Bluetooth headsets: both node formats report 48 kHz while
    // CoreAudio has switched the microphone hardware to 24 kHz. Installing a
    // tap with the stale rate raises an Objective-C exception instead of a
    // Swift error, so read the active device's nominal rate directly.
    let reportedFormat = input.outputFormat(forBus: 0)
    let inputFormat = input.inputFormat(forBus: 0)
    let channelCount =
      reportedFormat.channelCount > 0 ? reportedFormat.channelCount : inputFormat.channelCount
    let sampleRate = hardwareInputSampleRate(for: input) ?? reportedFormat.sampleRate
    guard sampleRate > 0, channelCount > 0,
      let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channelCount, interleaved: false),
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
        channels: 1, interleaved: false
      )
    else {
      throw NSError(
        domain: "MicrophoneRecorder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No microphone input is available"])
    }
    let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
    // Pin the tap to the valid native format. Passing nil can select an
    // unusable zero-channel format on some devices.
    input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, _ in
      guard let self else { return }
      let converted: AVAudioPCMBuffer
      if let converter {
        let capacity =
          AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 1
        guard let result = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
          return
        }
        var conversionError: NSError?
        let input = ConverterInput(buffer: buffer)
        converter.convert(to: result, error: &conversionError) { _, status in
          input.next(status: status)
        }
        guard conversionError == nil else { return }
        converted = result
      } else {
        converted = buffer
      }
      guard let channel = converted.floatChannelData?[0] else { return }
      let samples = (0..<Int(converted.frameLength)).map { index -> Int16 in
        Int16(max(-1, min(1, channel[index])) * 32767)
      }
      self.write(samples)
      let (handler, positionHandler, position) = self.lock.withLock {
        (self.samplesHandler, self.positionHandler, self.byteCount / MemoryLayout<Int16>.size)
      }
      handler?(samples)
      positionHandler?(samples, position)
    }
    lock.withLock { tapping = true }
    engine.prepare()
    do { try engine.start() } catch {
      input.removeTap(onBus: 0)
      lock.withLock { tapping = false }
      throw error
    }
  }

  private func hardwareInputSampleRate(for input: AVAudioInputNode) -> Double? {
    guard let audioUnit = input.audioUnit else { return nil }
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(
      audioUnit, kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global, 0, &deviceID, &deviceSize
    ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var sampleRate = Float64(0)
    var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(
      deviceID, &address, 0, nil, &sampleRateSize, &sampleRate
    ) == noErr, sampleRate > 0 else { return nil }
    return sampleRate
  }

  func stop() throws -> URL? {
    pause()
    lock.lock()
    defer { lock.unlock() }
    let finalizeHandle = handle
    let finalizeBytes = byteCount
    let recordedError = writeError
    let result = outputURL
    // Clear state up front so a throwing finalize cannot orphan the handle
    // and leave the recorder wedged for the next capture.
    handle = nil
    outputURL = nil
    alignmentClock = nil
    writeError = nil
    if let finalizeHandle { try WavFile.finalize(finalizeHandle, bytes: finalizeBytes) }
    if let recordedError { throw recordedError }
    return result
  }

  private func write(_ samples: [Int16]) {
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    lock.lock()
    defer { lock.unlock() }
    guard writeError == nil else { return }
    do {
      if needsAlignment, let alignmentClock {
        // Pad-only drift correction: when a segment starts behind the shared
        // capture clock we insert silence to catch up, but a source that runs
        // ahead (clock skew, buffered device samples) is never trimmed. Small
        // positive drift between mic and system tracks can therefore persist;
        // trimming was rejected because it would drop real audio.
        let missing = max(
          0, alignmentClock.samplePosition - byteCount / MemoryLayout<Int16>.size)
        if missing > 0 {
          let silence = WavFile.silence(samples: missing)
          try handle?.write(contentsOf: silence)
          byteCount += silence.count
        }
        needsAlignment = false
      }
      try handle?.write(contentsOf: data)
      byteCount += data.count
      bytesSinceCheckpoint += data.count
      if bytesSinceCheckpoint >= Int(WavFile.sampleRate) * MemoryLayout<Int16>.size {
        try handle.map { try WavFile.checkpoint($0, bytes: byteCount) }
        bytesSinceCheckpoint = 0
      }
    } catch {
      writeError = error
    }
  }
}

private final class ConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard !supplied else {
      status.pointee = .noDataNow
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}
