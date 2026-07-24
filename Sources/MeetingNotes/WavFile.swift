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
  static func hasMeaningfulSignal(at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44 else {
      return false
    }
    return data.withUnsafeBytes { bytes in
      let allSamples = bytes.bindMemory(to: Int16.self)
      guard allSamples.count > 22 else { return false }
      let samples = allSamples.dropFirst(22)
      // Require roughly 0.1% of the recording to contain a signal above
      // low-level capture noise, with a 100 ms floor for short recordings.
      let requiredActiveSamples = max(1_600, samples.count / 1_000)
      var activeSamples = 0
      for sample in samples where abs(Int(sample)) >= 96 {
        activeSamples += 1
        if activeSamples >= requiredActiveSamples { return true }
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
