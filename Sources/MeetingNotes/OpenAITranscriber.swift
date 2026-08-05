import Foundation

enum TranscriptionEngineOption: String, CaseIterable, Sendable {
  case onDevice
  case openAI

  var label: String {
    switch self {
    case .onDevice: "On-device"
    case .openAI: "OpenAI API"
    }
  }
}

enum OpenAIKeyTestState: Equatable, Sendable {
  case idle
  case testing
  case succeeded
  case failed(String)
}

enum TranscriptionEngineSettingsStore {
  private static let key = "transcription.engine"

  static func load(from defaults: UserDefaults = .standard) -> TranscriptionEngineOption {
    guard let rawValue = defaults.string(forKey: key) else { return .onDevice }
    return TranscriptionEngineOption(rawValue: rawValue) ?? .onDevice
  }

  static func save(_ option: TranscriptionEngineOption, to defaults: UserDefaults = .standard) {
    defaults.set(option.rawValue, forKey: key)
  }
}

/// Stores the OpenAI transcription API key as a generic Keychain password,
/// mirroring HookHeaderKeychainStore.
enum OpenAITranscribeKeychainStore {
  static let service = "app.meetingnotes.menu.openai-transcribe"
  private static let account = "api-key"

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  @discardableResult
  static func save(_ key: String) -> Bool {
    let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
      return false
    }
    guard !key.isEmpty else { return true }
    var item = baseQuery
    item[kSecValueData as String] = Data(key.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  static func load() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

enum OpenAITranscriber {
  static let fileModel = "gpt-transcribe"
  static let liveModel = "gpt-live-transcribe"
  static let transcriptionsURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
  static let realtimeURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
  /// 10 minutes of 16 kHz mono Int16 ≈ 19.2 MB, safely under the 25 MB upload cap.
  static let chunkSamples = 10 * 60 * 16_000

  /// Verifies the key and model access in one request.
  static func testKey(_ apiKey: String) async -> String? {
    var request = URLRequest(
      url: URL(string: "https://api.openai.com/v1/models/\(fileModel)")!)
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 200 { return nil }
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      return ((json?["error"] as? [String: Any])?["message"] as? String)
        ?? "HTTP \(status)"
    } catch {
      return error.localizedDescription
    }
  }

  struct Piece: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  struct ChunkRange: Equatable {
    let offset: Int
    let count: Int
  }

  struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func chunkRanges(totalSamples: Int, chunkSamples: Int = chunkSamples) -> [ChunkRange] {
    guard totalSamples > 0, chunkSamples > 0 else { return [] }
    return stride(from: 0, to: totalSamples, by: chunkSamples).map { offset in
      ChunkRange(offset: offset, count: min(chunkSamples, totalSamples - offset))
    }
  }

  /// Keywords must not contain angle brackets or line breaks per the API rules.
  static func sanitizedKeyword(_ keyword: String) -> String {
    keyword
      .components(separatedBy: CharacterSet(charactersIn: "<>\r\n"))
      .joined()
      .trimmingCharacters(in: .whitespaces)
  }

  static func vocabularyPrompt(
    entries: [VocabularyEntry] = VocabularySettingsStore.load()
  ) -> String? {
    let terms = entries.map { sanitizedKeyword($0.term) }.filter { !$0.isEmpty }
    guard !terms.isEmpty else { return nil }
    return "Expect these terms: " + terms.joined(separator: ", ")
  }

  static func multipartBody(
    boundary: String, model: String, prompt: String?, fileData: Data
  ) -> Data {
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
      body.append(Data("\(value)\r\n".utf8))
    }
    field("model", model)
    if let prompt { field("prompt", prompt) }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data(
      "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
    body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
    body.append(fileData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  /// Transcribes a 16 kHz mono WAV in chunks. Timestamps are chunk-coarse:
  /// each uploaded chunk becomes one piece spanning its position in the file.
  static func transcribe(url: URL, apiKey: String) async throws -> [Piece] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let totalSamples = max(0, (size - 44) / 2)
    let prompt = vocabularyPrompt()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var pieces: [Piece] = []
    for range in chunkRanges(totalSamples: totalSamples) {
      try handle.seek(toOffset: UInt64(44 + range.offset * 2))
      guard let data = try handle.read(upToCount: range.count * 2), !data.isEmpty else { break }
      let samples = int16Samples(from: data)
      let chunkURL = try WavFile.writeTemporary(samples: samples)
      defer { try? FileManager.default.removeItem(at: chunkURL) }
      let text = try await upload(
        fileData: try Data(contentsOf: chunkURL), prompt: prompt, apiKey: apiKey)
      let start = Double(range.offset) / 16_000
      let end = Double(range.offset + samples.count) / 16_000
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      pieces.append(Piece(start: start, end: end, text: trimmed))
    }
    return pieces
  }

  private static func upload(
    fileData: Data, prompt: String?, apiKey: String
  ) async throws -> String {
    let boundary = "meetingnotes-\(UUID().uuidString)"
    var request = URLRequest(url: transcriptionsURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartBody(
      boundary: boundary, model: fileModel, prompt: prompt, fileData: fileData)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard status == 200 else {
      let message = ((json?["error"] as? [String: Any])?["message"] as? String)
        ?? "OpenAI transcription failed (HTTP \(status))"
      throw APIError(message: message)
    }
    guard let text = json?["text"] as? String else {
      throw APIError(message: "OpenAI transcription returned no text")
    }
    return text
  }

  private static func int16Samples(from data: Data) -> [Int16] {
    let count = data.count / MemoryLayout<Int16>.size
    return data.withUnsafeBytes { rawBytes in
      let input = rawBytes.bindMemory(to: Int16.self)
      return (0..<count).map { Int16(littleEndian: input[$0]) }
    }
  }
}

/// One realtime transcription WebSocket per audio source. Emits the transcript
/// of each server-VAD segment when it completes; deltas are ignored for a
/// calmer live preview. The WAV capture remains the durable source of truth,
/// so any socket failure just ends the preview silently.
final class OpenAILiveSession: @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  private let onTranscript: @Sendable (String) -> Void
  private var receiveTask: Task<Void, Never>?

  init(apiKey: String, onTranscript: @escaping @Sendable (String) -> Void) {
    self.onTranscript = onTranscript
    var request = URLRequest(url: OpenAITranscriber.realtimeURL)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    task = URLSession.shared.webSocketTask(with: request)
    task.resume()
    // ponytail: rate 16000 matches our capture; docs only show 24000. If the
    // server rejects it, resample 2:3 before append.
    sendJSON([
      "type": "session.update",
      "session": [
        "type": "transcription",
        "audio": [
          "input": [
            "format": ["type": "audio/pcm", "rate": 16_000],
            "transcription": ["model": OpenAITranscriber.liveModel],
          ]
        ],
      ],
    ])
    receiveTask = Task { [weak self] in await self?.receiveLoop() }
  }

  func append(_ samples: [Int16]) {
    var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    sendJSON(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
  }

  func close() {
    receiveTask?.cancel()
    task.cancel(with: .goingAway, reason: nil)
  }

  private func sendJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let string = String(data: data, encoding: .utf8)
    else { return }
    task.send(.string(string)) { _ in }
  }

  private func receiveLoop() async {
    while !Task.isCancelled {
      guard let message = try? await task.receive() else { return }
      let data: Data
      switch message {
      case .string(let string): data = Data(string.utf8)
      case .data(let raw): data = raw
      @unknown default: continue
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let type = json["type"] as? String
      else { continue }
      if type == "conversation.item.input_audio_transcription.completed",
        let transcript = json["transcript"] as? String, !transcript.isEmpty {
        onTranscript(transcript)
      }
    }
  }
}
