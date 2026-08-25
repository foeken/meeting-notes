import Foundation

enum WavFile {
  static let sampleRate: UInt32 = 16_000
  static let channels: UInt16 = 1
  static let bitsPerSample: UInt16 = 16

  static func create(at url: URL) throws -> FileHandle {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: header(dataSize: 0))
    return handle
  }

  static func finalize(_ handle: FileHandle, bytes: Int) throws {
    try checkpoint(handle, bytes: bytes)
    try handle.close()
  }

  /// Keep the file recoverable if the process is suspended before `stop()`.
  static func checkpoint(_ handle: FileHandle, bytes: Int) throws {
    let end = try handle.offset()
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: header(dataSize: UInt32(clamping: bytes)))
    try handle.seek(toOffset: end)
    try handle.synchronize()
  }

  static func silence(samples: Int) -> Data {
    Data(count: max(0, samples) * MemoryLayout<Int16>.size)
  }

  /// Distinguishes a real captured signal from a correctly-sized silent WAV.
  /// ScreenCaptureKit writes silence for the full meeting when no system audio
  /// is playing, so file size alone cannot establish useful captured speech.
  ///
  /// Detection is RMS-windowed rather than a raw per-sample amplitude count so
  /// quiet-but-valid recordings (soft speakers, low input gain) are kept while
  /// true silence and DC-offset noise floors are still rejected.
  static func hasMeaningfulSignal(at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44 else {
      return false
    }
    return data.withUnsafeBytes { bytes in
      let allSamples = bytes.bindMemory(to: Int16.self)
      guard allSamples.count > 22 else { return false }
      let samples = allSamples.dropFirst(22)
      // 100 ms analysis windows; a window counts as active when its RMS rises
      // above a low noise floor. Require roughly 200 ms of active audio (one
      // window for very short files), scaled slightly for long recordings.
      let windowSize = Int(sampleRate) / 10
      let minimumRMS = 48.0
      let totalWindows = max(1, samples.count / windowSize)
      let requiredActiveWindows = max(min(2, totalWindows), totalWindows / 500)
      var activeWindows = 0
      var index = samples.startIndex
      while index < samples.endIndex {
        let end = min(index + windowSize, samples.endIndex)
        let count = end - index
        if count >= windowSize / 2 {
          var energy = 0.0
          for sampleIndex in index..<end {
            let value = Double(samples[sampleIndex])
            energy += value * value
          }
          if energy / Double(count) >= minimumRMS * minimumRMS {
            activeWindows += 1
            if activeWindows >= requiredActiveWindows { return true }
          }
        }
        index = end
      }
      return false
    }
  }

  static func writeTemporary(samples: [Int16]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
      .appendingPathExtension("wav")
    var data = header(dataSize: UInt32(clamping: samples.count * 2))
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    try data.write(to: url, options: .atomic)
    return url
  }

  static func repairHeader(at url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size >= 44 else { throw CocoaError(.fileReadCorruptFile) }
    let handle = try FileHandle(forUpdating: url)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: header(dataSize: UInt32(clamping: size - 44)))
    try handle.close()
  }

  private static func header(dataSize: UInt32) -> Data {
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    var result = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
    }
    result.append(contentsOf: "RIFF".utf8)
    append(dataSize.addingReportingOverflow(36).overflow ? UInt32.max : dataSize + 36)
    result.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16))
    append(UInt16(1))
    append(channels)
    append(sampleRate)
    append(byteRate)
    append(blockAlign)
    append(bitsPerSample)
    result.append(contentsOf: "data".utf8)
    append(dataSize)
    return result
  }
}

/// Tracks recent signal without retaining the recording or touching its file.
final class RecordingActivityMonitor: @unchecked Sendable {
  static let autoPauseDelay: TimeInterval = 15 * 60

  private let lock = NSLock()
  private var lastMeaningfulAt = Date.distantPast

  func reset(at date: Date = Date()) {
    lock.lock()
    lastMeaningfulAt = date
    lock.unlock()
  }

  func observe(_ samples: [Int16], at date: Date = Date()) {
    guard Self.hasMeaningfulSignal(samples) else { return }
    lock.lock()
    lastMeaningfulAt = max(lastMeaningfulAt, date)
    lock.unlock()
  }

  func isQuiet(for duration: TimeInterval = autoPauseDelay, at date: Date = Date()) -> Bool {
    lock.lock()
    let last = lastMeaningfulAt
    lock.unlock()
    return date.timeIntervalSince(last) >= duration
  }

  private static func hasMeaningfulSignal(_ samples: [Int16]) -> Bool {
    let windowSize = Int(WavFile.sampleRate) / 10
    guard samples.count >= windowSize / 2 else { return false }
    var index = 0
    while index < samples.count {
      let end = min(index + windowSize, samples.count)
      let count = end - index
      guard count >= windowSize / 2 else { break }
      var energy = 0.0
      for sample in samples[index..<end] {
        let value = Double(sample)
        energy += value * value
      }
      if energy / Double(count) >= 48.0 * 48.0 { return true }
      index = end
    }
    return false
  }
}
