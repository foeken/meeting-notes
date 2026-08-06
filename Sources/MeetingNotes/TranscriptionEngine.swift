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

  func invalidateVocabulary() {
    VocabularyTextCorrector.invalidate()
  }

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

enum VocabularyTextCorrector {
  private struct Replacement {
    let regex: NSRegularExpression
    let template: String
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cachedReplacements: [Replacement]?

  /// Drops the compiled patterns so the next correction re-reads settings.
  static func invalidate() {
    lock.lock()
    cachedReplacements = nil
    lock.unlock()
  }

  static func apply(to text: String) -> String {
    guard !text.isEmpty else { return text }
    return replacements().reduce(text) { corrected, replacement in
      let range = NSRange(corrected.startIndex..., in: corrected)
      guard replacement.regex.firstMatch(in: corrected, range: range) != nil else {
        return corrected
      }
      return replacement.regex.stringByReplacingMatches(
        in: corrected, range: range, withTemplate: replacement.template)
    }
  }

  private static func replacements() -> [Replacement] {
    lock.lock()
    defer { lock.unlock() }
    if let cachedReplacements { return cachedReplacements }
    let compiled = VocabularySettingsStore.load().flatMap { entry in
      entry.aliases.compactMap { alias -> Replacement? in
        guard let regex = try? NSRegularExpression(
          pattern: pattern(for: alias), options: [.caseInsensitive])
        else { return nil }
        return Replacement(
          regex: regex, template: NSRegularExpression.escapedTemplate(for: entry.term))
      }
    }
    cachedReplacements = compiled
    return compiled
  }

  /// `\b` misbehaves when an alias starts or ends with a non-word character
  /// (for example ".net" or "C++"): the boundary then anchors to the wrong
  /// side and the alias never matches. Explicit lookarounds keep whole-word
  /// semantics for ordinary aliases and still work for punctuated ones.
  private static func pattern(for alias: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: alias)
    let leading = alias.unicodeScalars.first.map(isWordScalar) ?? false
    let trailing = alias.unicodeScalars.last.map(isWordScalar) ?? false
    let prefix = leading ? #"(?<![\p{L}\p{N}])"# : ""
    let suffix = trailing ? #"(?![\p{L}\p{N}])"# : ""
    return prefix + escaped + suffix
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar)
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
    var openAISession: OpenAILiveSession?
    var sampleCount = 0
    var wavPosition: Int?
    var emittedThrough: TimeInterval = 0
    var transcript = ""
    var queue = SerialAudioBatchQueue()
    // Delta text held back until a sentence boundary, so the preview shows
    // whole sentences instead of chunk-sized fragments.
    var pendingText = ""
    var pendingStart: TimeInterval?
    // Stable id for the growing sentence: every delta re-emits the same turn
    // so the preview updates in place instead of stacking fragments.
    var pendingTurnID: UUID?
  }

  private let transcriber: NemotronTranscriber
  private var states: [TranscriptTurn.Source: StreamState] = [
    .microphone: StreamState(), .system: StreamState(),
  ]
  private var onTurn: TurnHandler?
  private var running = false
  private var sessionID: UUID?
  private var openAIKey: String?

  init(transcriber: NemotronTranscriber) {
    self.transcriber = transcriber
  }

  @discardableResult
  func start(onTurn: @escaping TurnHandler) -> UUID {
    let sessionID = UUID()
    states = [.microphone: StreamState(), .system: StreamState()]
    self.onTurn = onTurn
    self.sessionID = sessionID
    openAIKey = TranscriptionEngineSettingsStore.loadLive() == .openAI
      ? OpenAITranscribeKeychainStore.load() : nil
    running = true
    return sessionID
  }

  /// `wavPosition` is the source recorder's WAV sample position (including
  /// alignment padding) after writing these samples. When provided, live turn
  /// timestamps follow the WAV clock and stay correct across pause/resume
  /// gaps; otherwise they fall back to counting delivered samples only.
  func append(
    _ samples: [Int16], source: TranscriptTurn.Source, sessionID: UUID,
    wavPosition: Int? = nil
  ) async {
    guard running, self.sessionID == sessionID, !samples.isEmpty else { return }
    if let openAIKey {
      appendToOpenAI(samples, source: source, apiKey: openAIKey, wavPosition: wavPosition)
      return
    }
    var state = states[source, default: StreamState()]
    let shouldDrain = state.queue.enqueue(samples)
    if let wavPosition { state.wavPosition = wavPosition }
    states[source] = state
    guard shouldDrain else { return }
    await drain(source: source, sessionID: sessionID)
  }

  private func appendToOpenAI(
    _ samples: [Int16], source: TranscriptTurn.Source, apiKey: String, wavPosition: Int?
  ) {
    var state = states[source, default: StreamState()]
    state.sampleCount += samples.count
    if let wavPosition { state.wavPosition = wavPosition }
    if state.openAISession == nil {
      let sessionID = self.sessionID
      state.openAISession = OpenAILiveSession(apiKey: apiKey) { [weak self] transcript in
        Task {
          guard let self, let sessionID else { return }
          await self.emitOpenAITranscript(transcript, source: source, sessionID: sessionID)
        }
      }
    }
    state.openAISession?.append(samples)
    states[source] = state
  }

  private func emitOpenAITranscript(
    _ transcript: String, source: TranscriptTurn.Source, sessionID: UUID
  ) async {
    guard running, self.sessionID == sessionID else { return }
    var state = states[source, default: StreamState()]
    let end = Double(state.wavPosition ?? state.sampleCount) / 16_000
    let rawText = VocabularyTextCorrector.apply(
      to: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    let text = FillerWordSettingsStore.load() ? FillerWordFilter.apply(rawText) : rawText
    guard !text.isEmpty else {
      state.emittedThrough = end
      states[source] = state
      return
    }
    let turn = TranscriptTurn(
      start: min(state.emittedThrough, end), end: end,
      speaker: "Unknown", text: text, source: source)
    state.emittedThrough = end
    states[source] = state
    await onTurn?(turn)
  }

  private func drain(source: TranscriptTurn.Source, sessionID: UUID) async {
    while running, self.sessionID == sessionID {
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
          guard running, self.sessionID == sessionID else { return }
          states[source, default: StreamState()].manager = manager
        }
        let floatSamples = samples.map { Float($0) / 32_768 }
        _ = try await manager.process(samples: floatSamples)
        guard running, self.sessionID == sessionID else { return }
        let partial = await manager.getPartialTranscript()
        guard running, self.sessionID == sessionID else { return }
        await emitNewText(partial, source: source, sessionID: sessionID)
      } catch {
        // The WAV capture remains the source of truth. Finalization retries with
        // a fresh Nemotron session if a live preview prediction fails.
        guard running, self.sessionID == sessionID else { return }
        states[source, default: StreamState()].manager = nil
      }
    }

    guard self.sessionID == sessionID else { return }
    var state = states[source, default: StreamState()]
    state.queue.cancel()
    states[source] = state
  }

  /// Stops accepting preview audio immediately. Final transcription uses the
  /// durable WAV files, so stopping a meeting must never wait for an in-flight
  /// Core ML preview prediction to finish.
  func finish() {
    running = false
    sessionID = nil
    openAIKey = nil
    // No held-back text to flush: every delta already re-emitted the growing
    // sentence under its stable id, so the store has the words up to the
    // stop click.
    for source in [TranscriptTurn.Source.microphone, .system] {
      states[source, default: StreamState()].queue.cancel()
      states[source, default: StreamState()].manager = nil
      states[source, default: StreamState()].openAISession?.close()
      states[source, default: StreamState()].openAISession = nil
    }
    onTurn = nil
  }

  /// Switches the running preview between the on-device engine and the
  /// OpenAI realtime API mid-meeting. The persisted setting is untouched, so
  /// the next meeting starts on the configured engine.
  func setLiveOpenAI(_ enabled: Bool) {
    guard running else { return }
    if enabled {
      guard openAIKey == nil,
        let key = OpenAITranscribeKeychainStore.load(), !key.isEmpty
      else { return }
      openAIKey = key
      for source in [TranscriptTurn.Source.microphone, .system] {
        states[source, default: StreamState()].manager = nil
      }
    } else {
      guard openAIKey != nil else { return }
      openAIKey = nil
      for source in [TranscriptTurn.Source.microphone, .system] {
        // close() flushes any sentence the realtime session still holds.
        states[source, default: StreamState()].openAISession?.close()
        states[source, default: StreamState()].openAISession = nil
      }
    }
  }

  private func emitNewText(
    _ currentText: String, source: TranscriptTurn.Source, sessionID: UUID
  ) async {
    guard running, self.sessionID == sessionID else { return }
    var state = states[source, default: StreamState()]
    let delta = NemotronTranscriber.appendedText(previous: state.transcript, current: currentText)
    state.transcript = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !delta.isEmpty else {
      states[source] = state
      return
    }
    let end = Double(state.wavPosition ?? state.sampleCount) / 16_000
    let rawText = VocabularyTextCorrector.apply(to: delta)
    let text = FillerWordSettingsStore.load() ? FillerWordFilter.apply(rawText) : rawText
    guard !text.isEmpty else {
      state.emittedThrough = end
      states[source] = state
      return
    }
    if state.pendingStart == nil {
      state.pendingStart = max(state.emittedThrough, end - 1.12)
    }
    state.pendingText = state.pendingText.isEmpty ? text : state.pendingText + " " + text
    state.emittedThrough = end
    // Every delta re-emits the growing sentence under a stable id, so the
    // preview flows continuously while the current line extends in place.
    let turnID = state.pendingTurnID ?? UUID()
    state.pendingTurnID = turnID
    let turn = TranscriptTurn(
      id: turnID,
      start: state.pendingStart ?? max(0, end - 1.12), end: end,
      speaker: "Unknown",
      text: state.pendingText, source: source)
    // Sentence closed (or ran long): the next delta starts a fresh turn.
    if OpenAILiveSession.shouldFlush(state.pendingText) || state.pendingText.count > 300 {
      state.pendingText = ""
      state.pendingStart = nil
      state.pendingTurnID = nil
    }
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
    if TranscriptionEngineSettingsStore.load() == .openAI,
      let apiKey = OpenAITranscribeKeychainStore.load(), !apiKey.isEmpty {
      do {
        return try await processWithOpenAI(microphone: microphone, system: system, apiKey: apiKey)
      } catch {
        // The WAVs stay on disk; a failed API call must never lose a meeting.
        // Fall back to on-device transcription.
      }
    }
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

  private func processWithOpenAI(
    microphone: URL, system: URL, apiKey: String
  ) async throws -> [TranscriptTurn] {
    var turns: [TranscriptTurn] = []
    for (url, source) in [(microphone, TranscriptTurn.Source.microphone), (system, .system)]
    where Self.hasUsableAudio(url) {
      let pieces = try await OpenAITranscriber.transcribe(url: url, apiKey: apiKey)
      turns += pieces.map { piece in
        TranscriptTurn(
          start: piece.start, end: piece.end,
          speaker: "Unknown",
          text: VocabularyTextCorrector.apply(to: piece.text), source: source)
      }
    }
    guard !turns.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    let mergedTurns = turns.sorted { $0.start < $1.start }
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
