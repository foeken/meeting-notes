import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// ScreenCaptureKit audio capture, adapted from Muesli's MIT-licensed recorder.
final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
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

  private let queue = DispatchQueue(label: "MeetingNotes.system-audio")
  private let lock = NSLock()
  private let logger = Logger(subsystem: "app.meetingnotes.menu", category: "SystemAudioRecorder")
  private var samplesHandler: (@Sendable ([Int16]) -> Void)?
  private var positionHandler: (@Sendable ([Int16], Int) -> Void)?
  private var stream: SCStream?
  private var handle: FileHandle?
  private var outputURL: URL?
  private var byteCount = 0
  private var recording = false
  private var alignmentClock: CaptureClock?
  private var needsAlignment = false
  private var bytesSinceCheckpoint = 0
  private var writeError: Error?
  private var reportedUnsupportedFormat = false

  func start(writingTo url: URL, clock: CaptureClock) async throws {
    let created = try WavFile.create(at: url)
    lock.withLock {
      handle = created
      outputURL = url
      byteCount = 0
      bytesSinceCheckpoint = 0
      writeError = nil
      alignmentClock = clock
      needsAlignment = true
      reportedUnsupportedFormat = false
    }
    do {
      try await startStream()
    } catch {
      lock.withLock {
        recording = false
        try? handle?.close()
        handle = nil
        outputURL = nil
        alignmentClock = nil
      }
      throw error
    }
  }

  func pause() async {
    suspendImmediately()
    if let stream { try? await stream.stopCapture() }
    stream = nil
  }

  /// Called directly from `willSleep`; it does not wait for ScreenCaptureKit.
  func suspendImmediately() {
    lock.lock()
    recording = false
    if let handle {
      do { try WavFile.checkpoint(handle, bytes: byteCount) } catch { writeError = error }
    }
    lock.unlock()
  }

  func resume() async throws {
    guard lock.withLock({ handle != nil }) else { return }
    if stream != nil { await pause() }
    lock.withLock { needsAlignment = true }
    try await startStream()
  }

  func stop() async throws -> URL? {
    await pause()
    return try finalizeFile()
  }

  private func startStream() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else {
      throw NSError(
        domain: "SystemAudioRecorder", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No display is available for system audio capture"])
    }
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.showsCursor = false
    configuration.capturesAudio = true
    configuration.sampleRate = 16_000
    configuration.channelCount = 1
    configuration.excludesCurrentProcessAudio = true
    let excludedIdentifiers = SystemAudioExclusionStore.excludedBundleIdentifiers()
    let excludedApps =
      excludedIdentifiers.isEmpty
      ? []
      : content.applications.filter { excludedIdentifiers.contains($0.bundleIdentifier) }
    let stream = SCStream(
      filter: SCContentFilter(
        display: display, excludingApplications: excludedApps, exceptingWindows: []),
      configuration: configuration,
      delegate: nil)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
    lock.withLock { recording = true }
  }

  private func finalizeFile() throws -> URL? {
    lock.lock()
    defer { lock.unlock() }
    let finalizeHandle = handle
    let finalizeBytes = byteCount
    let recordedError = writeError
    let result = outputURL
    // Clear state up front so a throwing finalize cannot orphan the handle
    // and leave stale write state behind for the next capture.
    handle = nil
    outputURL = nil
    alignmentClock = nil
    writeError = nil
    if let finalizeHandle { try WavFile.finalize(finalizeHandle, bytes: finalizeBytes) }
    if let recordedError { throw recordedError }
    return result
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, lock.withLock({ recording }),
      let block = CMSampleBufferGetDataBuffer(sampleBuffer),
      let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
    else { return }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { return }
    var pointer: UnsafeMutablePointer<Int8>?
    guard
      CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
        == kCMBlockBufferNoErr,
      let pointer
    else { return }

    let channels = max(1, Int(format.mChannelsPerFrame))
    let samples: [Int16]
    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
      let count = length / MemoryLayout<Float>.size
      let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
      samples = (0..<(count / channels)).map { frame in
        var sum: Float = 0
        for channel in 0..<channels { sum += floats[frame * channels + channel] }
        return Int16(max(-1, min(1, sum / Float(channels))) * 32767)
      }
    } else if format.mBitsPerChannel == 16 {
      let count = length / MemoryLayout<Int16>.size
      let integers = UnsafeRawPointer(pointer).bindMemory(to: Int16.self, capacity: count)
      samples = (0..<(count / channels)).map { frame in
        var sum = 0
        for channel in 0..<channels { sum += Int(integers[frame * channels + channel]) }
        return Int16(clamping: sum / channels)
      }
    } else {
      // Unsupported PCM layouts would otherwise disappear silently, producing
      // an inexplicably empty system track. Surface the first occurrence.
      let shouldReport = lock.withLock { () -> Bool in
        guard !reportedUnsupportedFormat else { return false }
        reportedUnsupportedFormat = true
        return true
      }
      if shouldReport {
        logger.error(
          "Dropping system audio: unsupported format (flags \(format.mFormatFlags), bits \(format.mBitsPerChannel))"
        )
      }
      return
    }
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    lock.lock()
    // The stream callback can race stop(): once finalizeFile() has cleared the
    // handle, late buffers must not keep mutating counters or padding state.
    guard writeError == nil, handle != nil else {
      lock.unlock()
      return
    }
    do {
      if needsAlignment, let alignmentClock {
        // Pad-only drift correction: see MicrophoneRecorder.write — silence is
        // inserted when this source lags the shared clock, but audio is never
        // trimmed when a source runs ahead, so small drift can persist.
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
    let handler = samplesHandler
    let positionHandler = positionHandler
    let position = byteCount / MemoryLayout<Int16>.size
    lock.unlock()
    handler?(samples)
    positionHandler?(samples, position)
  }
}
