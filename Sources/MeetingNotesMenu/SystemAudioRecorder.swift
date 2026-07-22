import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit audio capture, adapted from Muesli's MIT-licensed recorder.
final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
  var onSamples: (@Sendable ([Int16]) -> Void)?

  private let queue = DispatchQueue(label: "MeetingNotesMenu.system-audio")
  private let lock = NSLock()
  private var stream: SCStream?
  private var handle: FileHandle?
  private var outputURL: URL?
  private var byteCount = 0
  private var recording = false
  private var alignmentClock: CaptureClock?
  private var needsAlignment = false
  private var bytesSinceCheckpoint = 0
  private var writeError: Error?

  func start(writingTo url: URL, clock: CaptureClock) async throws {
    handle = try WavFile.create(at: url)
    outputURL = url
    byteCount = 0
    bytesSinceCheckpoint = 0
    writeError = nil
    alignmentClock = clock
    needsAlignment = true
    do {
      try await startStream()
    } catch {
      recording = false
      try? handle?.close()
      handle = nil
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
    recording = false
    lock.lock()
    if let handle {
      do { try WavFile.checkpoint(handle, bytes: byteCount) } catch { writeError = error }
    }
    lock.unlock()
  }

  func resume() async throws {
    guard handle != nil else { return }
    if stream != nil { await pause() }
    needsAlignment = true
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
    let stream = SCStream(
      filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration,
      delegate: nil)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
    recording = true
  }

  private func finalizeFile() throws -> URL? {
    lock.lock()
    defer { lock.unlock() }
    if let handle { try WavFile.finalize(handle, bytes: byteCount) }
    let recordedError = writeError
    handle = nil
    let result = outputURL
    outputURL = nil
    alignmentClock = nil
    writeError = nil
    if let recordedError { throw recordedError }
    return result
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, recording,
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
      return
    }
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    lock.lock()
    guard writeError == nil else {
      lock.unlock()
      return
    }
    do {
      if needsAlignment, let alignmentClock {
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
    lock.unlock()
    onSamples?(samples)
  }
}
