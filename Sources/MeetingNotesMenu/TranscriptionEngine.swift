import FluidAudio
import Foundation

actor NemotronTranscriber {
  struct Segment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
  }

  struct Result: Sendable {
    let text: String
    let duration: TimeInterval
    let segments: [Segment]
  }

  private static let language = "auto"
  private static let chunkMilliseconds = 1_120
  private static let sampleRate = 16_000
  private var sharedModels: SharedNemotronMultilingualModels?
  private var loadingTask: Task<SharedNemotronMultilingualModels, Error>?

  func prepare() async throws {
    if sharedModels != nil { return }
    if let loadingTask {
      sharedModels = try await loadingTask.value
      return
    }
    let task = Task {
      try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
        languageCode: Self.language,
        chunkMs: Self.chunkMilliseconds)
    }
    loadingTask = task
    do {
      sharedModels = try await task.value
      loadingTask = nil
    } catch {
      loadingTask = nil
      throw error
    }
  }

  func makeSession() async throws -> StreamingNemotronMultilingualAsrManager {
    try await prepare()
    guard let sharedModels else { throw CocoaError(.coderReadCorrupt) }
    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadFromShared(sharedModels)
    await manager.setLanguage(Self.language)
    await manager.setForcedPrefix(false)
    return manager
  }

  func transcribe(_ url: URL) async throws -> Result {
    let manager = try await makeSession()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: 44)

    let samplesPerChunk = Self.sampleRate * Self.chunkMilliseconds / 1_000
    let bytesPerChunk = samplesPerChunk * MemoryLayout<Int16>.size
    var sampleCount = 0
    var emittedThrough: TimeInterval = 0
    var previousText = ""
    var segments: [Segment] = []

    while let data = try handle.read(upToCount: bytesPerChunk), !data.isEmpty {
      let samples = Self.floatSamples(from: data)
      guard !samples.isEmpty else { continue }
      sampleCount += samples.count
      _ = try await manager.process(samples: samples)
      let partial = await manager.getPartialTranscript()
      appendDelta(
        in: partial,
        previousText: &previousText,
        emittedThrough: &emittedThrough,
        currentTime: Double(sampleCount) / Double(Self.sampleRate),
        segments: &segments)
    }

    let finalText = try await manager.finish()
    let duration = Double(sampleCount) / Double(Self.sampleRate)
    appendDelta(
      in: finalText,
      previousText: &previousText,
      emittedThrough: &emittedThrough,
      currentTime: duration,
      segments: &segments)
    let correctedText = VocabularyTextCorrector.apply(to: finalText)
    let correctedSegments = segments.map {
      Segment(start: $0.start, end: $0.end, text: VocabularyTextCorrector.apply(to: $0.text))
    }
    return Result(text: correctedText, duration: duration, segments: correctedSegments)
  }

  func invalidateVocabulary() {}

  nonisolated static func appendedText(previous: String, current: String) -> String {
    let old = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    let new = current.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !new.isEmpty, new != old else { return "" }
    if new.hasPrefix(old) {
      return String(new.dropFirst(old.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var oldIndex = old.startIndex
    var newIndex = new.startIndex
    while oldIndex < old.endIndex, newIndex < new.endIndex, old[oldIndex] == new[newIndex] {
      old.formIndex(after: &oldIndex)
      new.formIndex(after: &newIndex)
    }
    return String(new[newIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func appendDelta(
    in currentText: String,
    previousText: inout String,
    emittedThrough: inout TimeInterval,
    currentTime: TimeInterval,
    segments: inout [Segment]
  ) {
    let delta = Self.appendedText(previous: previousText, current: currentText)
    previousText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !delta.isEmpty else { return }
    let segmentStart = max(emittedThrough, currentTime - Double(Self.chunkMilliseconds) / 1_000)
    segments.append(Segment(start: segmentStart, end: currentTime, text: delta))
    emittedThrough = currentTime
  }

  private nonisolated static func floatSamples(from data: Data) -> [Float] {
    let count = data.count / MemoryLayout<Int16>.size
    return data.withUnsafeBytes { rawBytes in
      let input = rawBytes.bindMemory(to: Int16.self)
      return (0..<count).map { Float(Int16(littleEndian: input[$0])) / 32_768 }
    }
  }
}

private enum VocabularyTextCorrector {
  static func apply(to text: String) -> String {
    VocabularySettingsStore.load().reduce(text) { result, entry in
      entry.aliases.reduce(result) { corrected, alias in
        corrected.replacingOccurrences(
          of: "\\b\(NSRegularExpression.escapedPattern(for: alias))\\b",
          with: entry.term,
          options: [.regularExpression, .caseInsensitive])
      }
    }
  }
}

/// Coalesces capture callbacks behind a single async drain loop.
///
/// Swift actors are reentrant at every `await`. Without this queue, a second
/// capture callback can enter `StreamingNemotronMultilingualAsrManager.process`
/// while the first call is awaiting Core ML. FluidAudio's streaming manager
/// mutates one shared audio buffer, so concurrent calls can advance its read
/// offset twice and trap during buffer compaction.
struct SerialAudioBatchQueue: Sendable {
  private var pending: [Int16] = []
  private(set) var isDraining = false

  mutating func enqueue(_ samples: [Int16]) -> Bool {
    pending.append(contentsOf: samples)
    guard !isDraining else { return false }
    isDraining = true
    return true
  }

  mutating func takeNext() -> [Int16]? {
    guard !pending.isEmpty else { return nil }
    let batch = pending
    pending.removeAll(keepingCapacity: true)
    return batch
  }

  mutating func finishDraining() {
    isDraining = false
  }

  mutating func cancel() {
    pending.removeAll(keepingCapacity: false)
    isDraining = false
  }
}

actor LiveTranscriptionEngine {
  typealias TurnHandler = @Sendable (TranscriptTurn) async -> Void

  private struct StreamState {
    var manager: StreamingNemotronMultilingualAsrManager?
    var sampleCount = 0
    var emittedThrough: TimeInterval = 0
    var transcript = ""
    var queue = SerialAudioBatchQueue()
  }

  private let transcriber: NemotronTranscriber
  private var states: [TranscriptTurn.Source: StreamState] = [
    .microphone: StreamState(), .system: StreamState(),
  ]
  private var onTurn: TurnHandler?
  private var running = false

  init(transcriber: NemotronTranscriber) {
    self.transcriber = transcriber
  }

  func start(onTurn: @escaping TurnHandler) {
    states = [.microphone: StreamState(), .system: StreamState()]
    self.onTurn = onTurn
    running = true
  }

  func append(_ samples: [Int16], source: TranscriptTurn.Source) async {
    guard running, !samples.isEmpty else { return }
    var state = states[source, default: StreamState()]
    let shouldDrain = state.queue.enqueue(samples)
    states[source] = state
    guard shouldDrain else { return }
    await drain(source: source)
  }

  private func drain(source: TranscriptTurn.Source) async {
    while running {
      var state = states[source, default: StreamState()]
      guard let samples = state.queue.takeNext() else {
        state.queue.finishDraining()
        states[source] = state
        return
      }
      state.sampleCount += samples.count
      states[source] = state

      do {
        let manager: StreamingNemotronMultilingualAsrManager
        if let existing = states[source]?.manager {
          manager = existing
        } else {
          manager = try await transcriber.makeSession()
          states[source, default: StreamState()].manager = manager
        }
        let floatSamples = samples.map { Float($0) / 32_768 }
        _ = try await manager.process(samples: floatSamples)
        let partial = await manager.getPartialTranscript()
        await emitNewText(partial, source: source)
      } catch {
        // The WAV capture remains the source of truth. Finalization retries with
        // a fresh Nemotron session if a live preview prediction fails.
        states[source, default: StreamState()].manager = nil
      }
    }

    var state = states[source, default: StreamState()]
    state.queue.cancel()
    states[source] = state
  }

  func finish() async {
    running = false
    for source in [TranscriptTurn.Source.microphone, .system] {
      while states[source]?.queue.isDraining == true {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    for source in [TranscriptTurn.Source.microphone, .system] {
      guard let manager = states[source]?.manager else { continue }
      if let finalText = try? await manager.finish() {
        await emitNewText(finalText, source: source)
      }
    }
    onTurn = nil
  }

  private func emitNewText(_ currentText: String, source: TranscriptTurn.Source) async {
    var state = states[source, default: StreamState()]
    let delta = NemotronTranscriber.appendedText(previous: state.transcript, current: currentText)
    state.transcript = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !delta.isEmpty else {
      states[source] = state
      return
    }
    let end = Double(state.sampleCount) / 16_000
    let rawText = VocabularyTextCorrector.apply(to: delta)
    let text = FillerWordSettingsStore.load() ? FillerWordFilter.apply(rawText) : rawText
    guard !text.isEmpty else {
      state.emittedThrough = end
      states[source] = state
      return
    }
    let turn = TranscriptTurn(
      start: max(state.emittedThrough, end - 1.12), end: end,
      speaker: "Unknown",
      text: text, source: source)
    state.emittedThrough = end
    states[source] = state
    await onTurn?(turn)
  }
}

actor FinalTranscriptionEngine {
  private let transcriber: NemotronTranscriber

  init(transcriber: NemotronTranscriber) {
    self.transcriber = transcriber
  }

  func process(microphone: URL, system: URL) async throws -> [TranscriptTurn] {
    let mic = try await transcribeIfUsable(microphone)
    let remote = try await transcribeIfUsable(system)

    guard mic != nil || remote != nil else { throw CocoaError(.fileReadCorruptFile) }
    let micTurns = mic.map { Self.turns(from: $0, source: .microphone) } ?? []
    let remoteTurns = remote.map { Self.turns(from: $0, source: .system) } ?? []
    let mergedTurns = (micTurns + remoteTurns).sorted { $0.start < $1.start }
    return FillerWordSettingsStore.load()
      ? FillerWordFilter.apply(to: mergedTurns)
      : mergedTurns
  }

  private func transcribeIfUsable(_ url: URL) async throws -> NemotronTranscriber.Result? {
    guard Self.hasUsableAudio(url) else { return nil }
    return try await transcriber.transcribe(url)
  }

  nonisolated static func hasUsableAudio(_ url: URL) -> Bool {
    WavFile.hasMeaningfulSignal(at: url)
  }

  nonisolated static func turns(
    from result: NemotronTranscriber.Result, source: TranscriptTurn.Source
  ) -> [TranscriptTurn] {
    guard !result.segments.isEmpty else {
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty
        ? []
        : [
          TranscriptTurn(
            start: 0, end: result.duration,
            speaker: "Unknown", text: text, source: source)
        ]
    }

    return result.segments.compactMap { segment in
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return TranscriptTurn(
        start: segment.start, end: segment.end,
        speaker: "Unknown", text: text, source: source)
    }
  }
}
