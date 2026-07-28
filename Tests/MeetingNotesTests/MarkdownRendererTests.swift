import Foundation
import Testing

@Test func meetingSummaryGuidancePreservesSubstantiveContext() {
  #expect(OpenAIEnricher.summaryGuidance.contains("250–400 words"))
  #expect(OpenAIEnricher.summaryGuidance.contains("every major topic"))
  #expect(OpenAIEnricher.summaryGuidance.contains("disagreement"))
  #expect(!OpenAIEnricher.summaryGuidance.localizedLowercase.contains("concise"))
}

@testable import MeetingNotes

@Test func fillerWordFilterRemovesPausesWithoutDamagingWords() {
  #expect(FillerWordFilter.apply("So uh I was thinking um about this") == "So I was thinking about this")
  #expect(FillerWordFilter.apply("Uh, um, the answer is yes") == "The answer is yes")
  #expect(FillerWordFilter.apply("The umbrella is here") == "The umbrella is here")
  #expect(FillerWordFilter.apply("Her name is Uma") == "Her name is Uma")
}

@Test func fillerWordFilterKeepsAmbiguousDutchTokens() {
  // "er" and "mm" are real Dutch words; the language-blind filter must not
  // strip them even though English treats them as fillers.
  #expect(FillerWordFilter.apply("Er is nog koffie") == "Er is nog koffie")
  #expect(FillerWordFilter.apply("Hij is er al, mm 80 procent zeker") == "Hij is er al, mm 80 procent zeker")
  #expect(FillerWordFilter.apply("So err I think hmm we wait") == "So I think we wait")
}

@Test func fillerWordFilterHandlesCommonDisfluencyPhrasesConservatively() {
  #expect(FillerWordFilter.apply("I mean, we should ship") == "We should ship")
  #expect(FillerWordFilter.apply("I mean what I said") == "I mean what I said")
  #expect(FillerWordFilter.apply("It is kind of useful") == "It is kind of useful")
}

@Test func nemotronCumulativeTranscriptEmitsOnlyNewText() {
  #expect(NemotronTranscriber.appendedText(previous: "", current: "Hello") == "Hello")
  #expect(
    NemotronTranscriber.appendedText(previous: "Hello", current: "Hello everyone") == "everyone")
  #expect(NemotronTranscriber.appendedText(previous: "Hello", current: "Hello") == "")
}

@Test func nemotronLiveAudioUsesOnlyOneDrainLoopPerStream() {
  var queue = SerialAudioBatchQueue()

  #expect(queue.enqueue([1, 2]) == true)
  #expect(queue.enqueue([3]) == false)
  #expect(queue.enqueue([4, 5]) == false)
  #expect(queue.takeNext() == [1, 2, 3, 4, 5])
  #expect(queue.takeNext() == nil)

  queue.finishDraining()
  #expect(queue.enqueue([6]) == true)
  #expect(queue.takeNext() == [6])
}

@Test func chatGPTInstructionIncludesTheActualTranscriptPrompt() {
  let prompt = "TRANSCRIPT\\n[00:00:05] You: Ship the fix."
  let instruction = ChatGPTAuthService.instruction(prompt: prompt)

  #expect(instruction.contains(prompt))
  #expect(!instruction.contains("(prompt)"))
}

@Test func codexMeetingLinkTargetsOneProjectAndCarriesContextPolicy() throws {
  let context = CodexMeetingContext(
    meetingID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
    title: "Portfolio review",
    startedAt: Date(timeIntervalSince1970: 1_767_268_800),
    projectFolder: URL(fileURLWithPath: "/Users/test/Meeting Notes"),
    meetingFolder: URL(fileURLWithPath: "/Users/test/Meeting Notes/2026/01/01/review"))

  let prompt = CodexThreadService.initialPrompt(for: context)
  #expect(prompt.contains("Meeting ID: 12345678-1234-1234-1234-123456789ABC"))
  #expect(prompt.contains("If `live.md` exists"))
  #expect(prompt.contains("use it as the primary semantic overview"))
  #expect(prompt.contains("Do not read the complete `transcript.md` unless"))
  #expect(prompt.contains("Do not automatically extract decisions, tasks"))

  let customPrompt = CodexThreadService.initialPrompt(
    for: context,
    template: "Discuss {{meeting_title}} ({{meeting_id}}) in {{meeting_folder}} from {{project_folder}} at {{meeting_date}}")
  #expect(customPrompt.contains("Discuss Portfolio review (12345678-1234-1234-1234-123456789ABC)"))
  #expect(customPrompt.contains("in /Users/test/Meeting Notes/2026/01/01/review"))
  #expect(customPrompt.contains("from /Users/test/Meeting Notes"))
  #expect(!customPrompt.contains("{{meeting_date}}"))

  let threadURL = try #require(CodexThreadService.threadURL("thread-123"))
  #expect(threadURL.absoluteString == "codex://threads/thread-123")

  // The post-meeting instruction is personal, so nothing is sent by default.
  #expect(CodexThreadService.defaultSummaryMessageTemplate.isEmpty)
  #expect(CodexThreadService.summaryMessagePlaceholder.contains("task manager"))

  // Names and paths are substituted; whole documents never are, so the task
  // reads meeting.md from disk instead of receiving a copy.
  let customMessage = CodexThreadService.renderTemplate(
    "Notes ready for {{meeting_title}} in {{meeting_folder}}. Summary: {{summary}}",
    context: context)
  #expect(
    customMessage
      == "Notes ready for Portfolio review in /Users/test/Meeting Notes/2026/01/01/review. Summary: {{summary}}"
  )

  let completed: [String: Any] = [
    "method": "turn/completed",
    "params": ["threadId": "thread-123", "turn": ["id": "turn-9", "status": "completed"]],
  ]
  let outcome = try #require(
    CodexThreadService.turnOutcome(completed, threadID: "thread-123", turnID: "turn-9"))
  #expect((try? outcome.get()) != nil)
  #expect(
    CodexThreadService.turnOutcome(completed, threadID: "thread-123", turnID: "other") == nil)

  let failed: [String: Any] = [
    "method": "turn/failed",
    "params": [
      "threadId": "thread-123",
      "turn": ["id": "turn-9"],
      "error": ["message": "sandbox denied"],
    ],
  ]
  let failure = try #require(
    CodexThreadService.turnOutcome(failed, threadID: "thread-123", turnID: "turn-9"))
  #expect((try? failure.get()) == nil)

  let startParams = CodexThreadService.threadStartParams(for: context)
  #expect(startParams["cwd"] as? String == "/Users/test/Meeting Notes")
  #expect(startParams["runtimeWorkspaceRoots"] == nil)
  #expect(startParams["ephemeral"] as? Bool == false)
  // No model configured means Codex keeps deciding, as before.
  #expect(startParams["model"] == nil)
  #expect(startParams["config"] == nil)

  let chosen = CodexThreadService.threadStartParams(
    for: context, model: "gpt-5.6-terra", reasoningEffort: "high")
  #expect(chosen["model"] as? String == "gpt-5.6-terra")
  #expect((chosen["config"] as? [String: Any])?["model_reasoning_effort"] as? String == "high")

  // A model without an effort leaves the effort to Codex.
  let modelOnly = CodexThreadService.threadStartParams(
    for: context, model: "gpt-5.6-terra", reasoningEffort: "")
  #expect(modelOnly["model"] as? String == "gpt-5.6-terra")
  #expect(modelOnly["config"] == nil)

  // A blank model must never be sent as an empty string.
  let blank = CodexThreadService.threadStartParams(
    for: context, model: "  ", reasoningEffort: "high")
  #expect(blank["model"] == nil)

  let turnInput = CodexThreadService.turnInput(for: context)
  #expect(turnInput["type"] as? String == "text")
  #expect(turnInput["text"] as? String == prompt)

  let visibleEvent: [String: Any] = [
    "method": "item/started",
    "params": [
      "threadId": "thread-1",
      "item": ["type": "userMessage"],
    ],
  ]
  #expect(CodexThreadService.isVisibleUserMessageEvent(visibleEvent, threadID: "thread-1"))
  #expect(!CodexThreadService.isVisibleUserMessageEvent(visibleEvent, threadID: "thread-2"))

}

@Test func codexPromptSettingsPersistAndRestoreTheDefault() throws {
  let suite = "CodexPromptSettingsTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(CodexPromptSettingsStore.load(from: defaults) == CodexThreadService.defaultPromptTemplate)
  CodexPromptSettingsStore.save("Custom {{meeting_title}}", to: defaults)
  #expect(CodexPromptSettingsStore.load(from: defaults) == "Custom {{meeting_title}}")
  #expect(CodexPromptSettingsStore.restoreDefault(to: defaults) == CodexThreadService.defaultPromptTemplate)
  #expect(CodexPromptSettingsStore.load(from: defaults) == CodexThreadService.defaultPromptTemplate)
}

@Test func meetingDocumentPersistsItsCodexThreadID() throws {
  let original = MeetingDocument(
    id: UUID(), title: "Review", startedAt: Date(), status: .complete, transcript: [],
    codexThreadID: "019f6a03-a101-7d43-bba8-abdd82618540")
  let restored = try JSONDecoder().decode(
    MeetingDocument.self, from: JSONEncoder().encode(original))
  #expect(restored.codexThreadID == original.codexThreadID)
}

@Test func meetingDetectionRequiresCameraMicrophoneAndRecognizedApp() {
  let zoom = MeetingAppDetector.RunningApp(bundleIdentifier: "us.zoom.xos", isActive: true)
  #expect(MeetingAppDetector.detectedApp(
    cameraActive: true, microphoneActive: true, apps: [zoom]) == "Zoom")
  #expect(MeetingAppDetector.detectedApp(
    cameraActive: true, microphoneActive: false, apps: [zoom]) == nil)
  #expect(MeetingAppDetector.detectedApp(
    cameraActive: false, microphoneActive: true, apps: [zoom]) == nil)
  #expect(MeetingAppDetector.detectedApp(
    cameraActive: true, microphoneActive: true,
    apps: [.init(bundleIdentifier: "com.apple.PhotoBooth", isActive: true)]) == nil)
}

@Test func browserMeetingDetectionRequiresChromeToBeFrontmost() {
  let backgroundChrome = MeetingAppDetector.RunningApp(
    bundleIdentifier: "com.google.Chrome", isActive: false)
  let activeChrome = MeetingAppDetector.RunningApp(
    bundleIdentifier: "com.google.Chrome", isActive: true)
  #expect(MeetingAppDetector.detectedApp(
    cameraActive: true, microphoneActive: true, apps: [backgroundChrome]) == nil)
  #expect(MeetingAppDetector.detectedApp(
    cameraActive: true, microphoneActive: true, apps: [activeChrome]) == "Chrome")
}

@Test func browserMeetingDetectionRecognizesOtherActiveBrowsers() {
  for (identifier, name) in [
    ("com.apple.Safari", "Safari"),
    ("company.thebrowser.Browser", "Arc"),
    ("com.microsoft.edgemac", "Edge"),
  ] {
    let active = MeetingAppDetector.RunningApp(bundleIdentifier: identifier, isActive: true)
    let background = MeetingAppDetector.RunningApp(bundleIdentifier: identifier, isActive: false)
    #expect(MeetingAppDetector.detectedApp(
      cameraActive: true, microphoneActive: true, apps: [active]) == name)
    #expect(MeetingAppDetector.detectedApp(
      cameraActive: true, microphoneActive: true, apps: [background]) == nil)
  }
}

@MainActor
@Test func meetingAutoStopWaitsForGracePeriodAndCancelsWhenDetectionReturns() async throws {
  let scheduler = MeetingAutoStopScheduler()
  var stopCount = 0
  let stop: @MainActor @Sendable () async -> Void = { stopCount += 1 }

  scheduler.update(
    recordingMeetingApp: "Zoom", detectedMeetingApp: nil, isCapturing: true,
    gracePeriod: .milliseconds(20), stop: stop)
  scheduler.update(
    recordingMeetingApp: "Zoom", detectedMeetingApp: "Zoom", isCapturing: true,
    gracePeriod: .milliseconds(20), stop: stop)
  try await Task.sleep(for: .milliseconds(40))
  #expect(stopCount == 0)

  scheduler.update(
    recordingMeetingApp: "Zoom", detectedMeetingApp: nil, isCapturing: true,
    gracePeriod: .milliseconds(20), stop: stop)
  try await Task.sleep(for: .milliseconds(40))
  #expect(stopCount == 1)
}

@MainActor
@Test func meetingAutoStopDoesNotCancelItsOwnStopCallback() async throws {
  let scheduler = MeetingAutoStopScheduler()
  var callbackWasCancelled = false

  scheduler.update(
    recordingMeetingApp: "Zoom", detectedMeetingApp: nil, isCapturing: true,
    gracePeriod: .milliseconds(20)
  ) {
    // This mirrors AppModel.stop(), which cancels any still-pending automatic
    // stop before beginning the asynchronous transcription pipeline.
    scheduler.cancel()
    do {
      try await Task.sleep(for: .milliseconds(1))
    } catch {
      callbackWasCancelled = error is CancellationError
    }
  }

  try await Task.sleep(for: .milliseconds(50))
  #expect(!callbackWasCancelled)
}

@Test func rendersTimestampedMarkdown() {
  let meeting = MeetingDocument(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    title: "Roadmap & planning",
    startedAt: Date(timeIntervalSince1970: 0),
    status: .recording,
    transcript: [
      TranscriptTurn(start: 305, end: 307, speaker: "Speaker 1", text: "Ship it.", source: .system)
    ]
  )
  let output = MarkdownRenderer.renderLive(meeting)
  #expect(output.contains("# Roadmap & planning"))
  #expect(output.contains("**[00:05:05] Speaker 1:** Ship it."))
  #expect(output.contains("status: recording"))
}

@Test func makesSafeFilenames() {
  #expect("Café / Planning!".filenameSafe == "cafe-planning")
  #expect("Penny - Tags, Teams & Insights".filenameSafe == "penny-tags-teams-insights")
}

@Test func topicSegmentedTranscriptEmitsEveryTurnExactlyOnce() {
  // Topics leave gaps (0–10 and 30–40 covered; 10–30 and >40 uncovered) and the
  // straddling turn at 8–12 overlaps the first topic boundary.
  let insights = MeetingInsights(
    summary: "Summary",
    topics: [
      TopicInsight(title: "Kickoff", summary: "Start", start: 0, end: 10),
      TopicInsight(title: "Planning", summary: "Middle", start: 30, end: 40),
    ],
    decisions: [], actionItems: [], openQuestions: [], keyStatements: [],
    generatedAt: Date(timeIntervalSince1970: 0), generator: "test"
  )
  let meeting = MeetingDocument(
    id: UUID(), title: "Coverage", startedAt: Date(timeIntervalSince1970: 0),
    status: .complete,
    transcript: [
      TranscriptTurn(start: 2, end: 4, speaker: "A", text: "Inside first topic.", source: .system),
      TranscriptTurn(start: 8, end: 12, speaker: "B", text: "Straddles the boundary.", source: .system),
      TranscriptTurn(start: 18, end: 20, speaker: "C", text: "In the gap between topics.", source: .system),
      TranscriptTurn(start: 32, end: 34, speaker: "D", text: "Inside second topic.", source: .system),
      TranscriptTurn(start: 50, end: 52, speaker: "E", text: "After the last topic.", source: .system),
    ],
    insights: insights
  )
  let output = MarkdownRenderer.renderTranscript(meeting)

  // Every turn appears exactly once, including gap and post-topic turns.
  for text in [
    "Inside first topic.", "Straddles the boundary.", "In the gap between topics.",
    "Inside second topic.", "After the last topic.",
  ] {
    #expect(output.components(separatedBy: text).count == 2, "expected \(text) exactly once")
  }

  // Turns outside all topics land in a trailing "Other" section.
  #expect(output.contains("## Other"))
  let other = output.components(separatedBy: "## Other").last ?? ""
  #expect(other.contains("In the gap between topics."))
  #expect(other.contains("After the last topic."))

  // The straddling turn is assigned to the first overlapping topic.
  let kickoff = output.components(separatedBy: "## Kickoff").last?
    .components(separatedBy: "## ").first ?? ""
  #expect(kickoff.contains("Straddles the boundary."))
}

@Test func topicSegmentedTranscriptOmitsEmptyOtherSection() {
  let insights = MeetingInsights(
    summary: "Summary",
    topics: [TopicInsight(title: "Everything", summary: "All", start: 0, end: 100)],
    decisions: [], actionItems: [], openQuestions: [], keyStatements: [],
    generatedAt: Date(timeIntervalSince1970: 0), generator: "test"
  )
  let meeting = MeetingDocument(
    id: UUID(), title: "No leftovers", startedAt: Date(timeIntervalSince1970: 0),
    status: .complete,
    transcript: [
      TranscriptTurn(start: 5, end: 6, speaker: "A", text: "Covered.", source: .system)
    ],
    insights: insights
  )
  let output = MarkdownRenderer.renderTranscript(meeting)
  #expect(!output.contains("## Other"))
  #expect(output.contains("Covered."))
}

@Test func yamlFrontmatterEscapesNewlinesInTitle() {
  let meeting = MeetingDocument(
    id: UUID(), title: "Line one\nLine two", startedAt: Date(timeIntervalSince1970: 0),
    status: .recording, transcript: []
  )
  let output = MarkdownRenderer.renderLive(meeting)
  #expect(output.contains("title: \"Line one\\nLine two\""))
  // The heading collapses the newline instead of breaking Markdown structure.
  #expect(output.contains("# Line one Line two — Live transcript"))
}

@Test func finalStatusRendersAsComplete() {
  let meeting = MeetingDocument(
    id: UUID(), title: "Done", startedAt: Date(timeIntervalSince1970: 0),
    endedAt: Date(timeIntervalSince1970: 60), status: .complete, transcript: []
  )
  #expect(MarkdownRenderer.renderLive(meeting).contains("status: complete"))
}

@Test func successfulFinalizationReplacesLiveFile() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "Lifecycle", calendar: nil)
  let liveURL = try #require(await store.audioURL(named: "live.md"))
  let meetingURL = try #require(await store.audioURL(named: "meeting.md"))
  let transcriptURL = try #require(await store.audioURL(named: "transcript.md"))

  #expect(FileManager.default.fileExists(atPath: liveURL.path))
  #expect(!FileManager.default.fileExists(atPath: meetingURL.path))
  #expect(!FileManager.default.fileExists(atPath: transcriptURL.path))

  try await store.replaceTranscript([], status: .complete)
  #expect(!FileManager.default.fileExists(atPath: liveURL.path))
  #expect(FileManager.default.fileExists(atPath: meetingURL.path))
  #expect(FileManager.default.fileExists(atPath: transcriptURL.path))
}

@Test func successfulProcessingCanRemoveRecoveryAudio() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "Audio cleanup", calendar: nil)
  let microphone = try #require(await store.audioURL(named: "microphone.wav"))
  let system = try #require(await store.audioURL(named: "system.wav"))
  try Data("wav".utf8).write(to: microphone)
  try Data("wav".utf8).write(to: system)

  try await store.finalize(insights: nil)
  try await store.removeAudioFiles()

  #expect(!FileManager.default.fileExists(atPath: microphone.path))
  #expect(!FileManager.default.fileExists(atPath: system.path))
}

@Test func longTranscriptsAreSplitWithoutLosingTurns() {
  let longText = String(repeating: "meeting detail ", count: 7_000)
  let turns = [
    TranscriptTurn(start: 0, end: 10, speaker: "You", text: longText, source: .microphone),
    TranscriptTurn(start: 10, end: 20, speaker: "Speaker 1", text: longText, source: .system),
  ]
  let chunks = OpenAIEnricher.transcriptChunks(turns)
  #expect(chunks.count >= 2)
  #expect(chunks.allSatisfy { $0.count <= OpenAIEnricher.transcriptChunkCharacterLimit })
  // Timestamps stay on every prompt line so the model can answer time-scoped
  // questions. A real speaker name is still rendered when one exists.
  #expect(chunks.joined().contains("[00:00:00] You:"))
  #expect(chunks.joined().contains("[00:00:10] Speaker 1:"))
}

@Test func captureClockDoesNotCountPausedTime() async throws {
  let clock = CaptureClock()
  clock.start()
  try await Task.sleep(for: .milliseconds(20))
  let beforePause = clock.pause()
  try await Task.sleep(for: .milliseconds(30))
  #expect(abs(clock.elapsed - beforePause) < 0.01)
  clock.resume()
  try await Task.sleep(for: .milliseconds(20))
  #expect(clock.elapsed >= beforePause + 0.01)
}

@Test func recordingWakeLockCanBeAcquiredAndReleased() {
  let wakeLock = RecordingWakeLock()
  #expect(!wakeLock.isHeld)
  wakeLock.acquire()
  #expect(wakeLock.isHeld)
  wakeLock.acquire()
  #expect(wakeLock.isHeld)
  wakeLock.release()
  #expect(!wakeLock.isHeld)
}

@Test func wavCheckpointLeavesRecoverableHeader() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    .appendingPathExtension("wav")
  defer { try? FileManager.default.removeItem(at: url) }
  let handle = try WavFile.create(at: url)
  let payload = Data(repeating: 1, count: 32_000)
  try handle.write(contentsOf: payload)
  try WavFile.checkpoint(handle, bytes: payload.count)

  let data = try Data(contentsOf: url)
  #expect(data.count == payload.count + 44)
  let riffSize =
    UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
  #expect(riffSize == UInt32(payload.count + 36))
  try handle.close()
}

@Test func meaningfulSignalDetectionIgnoresSilentCaptureTracks() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let silentURL = root.appending(path: "silent.wav")
  let silentHandle = try WavFile.create(at: silentURL)
  let silentData = WavFile.silence(samples: 32_000)
  try silentHandle.write(contentsOf: silentData)
  try WavFile.finalize(silentHandle, bytes: silentData.count)

  let speechURL = root.appending(path: "speech.wav")
  let speechHandle = try WavFile.create(at: speechURL)
  let speechSamples = [Int16](repeating: 1_000, count: 32_000)
  var speechData = Data()
  speechSamples.withUnsafeBufferPointer { speechData.append(Data(buffer: $0)) }
  try speechHandle.write(contentsOf: speechData)
  try WavFile.finalize(speechHandle, bytes: speechData.count)

  #expect(!WavFile.hasMeaningfulSignal(at: silentURL))
  #expect(WavFile.hasMeaningfulSignal(at: speechURL))
  #expect(!FinalTranscriptionEngine.hasUsableAudio(silentURL))
  #expect(FinalTranscriptionEngine.hasUsableAudio(speechURL))
}

@Test func finalTranscriptionKeepsSegmentsAsNeutralUnknownTurns() {
  let result = NemotronTranscriber.Result(
    text: "First turn. Second turn.", duration: 4,
    segments: [
      NemotronTranscriber.Segment(start: 0, end: 1.5, text: "First turn."),
      NemotronTranscriber.Segment(start: 1.6, end: 4, text: "Second turn."),
    ])

  let turns = FinalTranscriptionEngine.turns(from: result, source: .system)
  #expect(turns.count == 2)
  #expect(turns.map(\.speaker) == ["Unknown", "Unknown"])
  #expect(turns.map(\.text) == ["First turn.", "Second turn."])
}

@Test func persistedSpeakerNamesAreNormalizedToUnknown() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  let meeting = try await store.begin(title: "Legacy labels", calendar: nil)
  try await store.replaceTranscript(
    [
      TranscriptTurn(start: 0, end: 1, speaker: "Speaker S1", text: "First", source: .system),
      TranscriptTurn(start: 2, end: 3, speaker: "Alex", text: "Second", source: .microphone),
    ], status: .complete)

  await store.normalizeMeetingDocuments()

  let updated = try #require(await store.current())
  #expect(updated.id == meeting.id)
  #expect(updated.transcript.map(\.speaker) == ["Unknown", "Unknown"])
  let folder = try #require(await store.currentFolder())
  let transcript = try String(
    contentsOf: folder.appending(path: "transcript.md"), encoding: .utf8)
  #expect(!transcript.contains("Speaker S1"))
  #expect(!transcript.contains("Alex:"))
  // The placeholder speaker is no longer printed at all; timestamps remain so
  // content stays locatable by time.
  #expect(!transcript.contains("Unknown:"))
  #expect(transcript.contains("[00:00:00]"))
  #expect(transcript.contains("First"))
  #expect(transcript.contains("Second"))
  let state = try String(
    contentsOf: folder.appending(path: "meeting.json"), encoding: .utf8)
  #expect(!state.contains("speakerNames"))
  #expect(!state.contains("transcriptFinalized"))
}

@Test func pointerTracksPauseTitleAndFailure() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "First title", calendar: nil)
  try await store.updateTitle("Changed title", captureState: "paused")

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  var pointer = try decoder.decode(
    CurrentMeetingPointer.self, from: Data(contentsOf: root.appending(path: "current.json")))
  #expect(pointer.active)
  #expect(pointer.title == "Changed title")
  #expect(pointer.captureState == "paused")

  try await store.setStatus(.failed)
  pointer = try decoder.decode(
    CurrentMeetingPointer.self, from: Data(contentsOf: root.appending(path: "current.json")))
  #expect(!pointer.active)
  #expect(pointer.captureState == "failed")
}

@Test func stoppedMeetingFinalizationDoesNotReplaceANewActiveMeeting() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)

  let first = try await store.begin(title: "First", calendar: nil)
  let stopped = try await store.prepareForFinalization()
  let second = try await store.begin(title: "Second", calendar: nil)
  let turn = TranscriptTurn(
    start: 0, end: 1, speaker: "Unknown", text: "Saved separately", source: .microphone)
  _ = try await store.finalizeStoppedMeeting(in: stopped.folder, turns: [turn], insights: nil)

  #expect((await store.current())?.id == second.id)

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let completed = try decoder.decode(
    MeetingDocument.self, from: Data(contentsOf: stopped.folder.appending(path: "meeting.json")))
  #expect(completed.id == first.id)
  #expect(completed.status == .complete)
  #expect(completed.transcript == [turn])

  let pointer = try decoder.decode(
    CurrentMeetingPointer.self, from: Data(contentsOf: root.appending(path: "current.json")))
  #expect(pointer.active)
  #expect(pointer.meetingID == second.id)
}

@Test func stoppedMeetingFinalizationCompletesPointerWhenNoNewMeetingStarted() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)

  let meeting = try await store.begin(title: "Only meeting", calendar: nil)
  let stopped = try await store.prepareForFinalization()
  _ = try await store.finalizeStoppedMeeting(in: stopped.folder, turns: [], insights: nil)

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let pointer = try decoder.decode(
    CurrentMeetingPointer.self, from: Data(contentsOf: root.appending(path: "current.json")))
  #expect(!pointer.active)
  #expect(pointer.meetingID == meeting.id)
  #expect(pointer.captureState == "complete")
}

@Test func completedMeetingLookupDoesNotReplaceTheActiveMeeting() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)

  let completed = try await store.begin(title: "Completed", calendar: nil)
  try await store.replaceTranscript([], status: .complete)
  let active = try await store.begin(title: "Active", calendar: nil)

  let found = try await store.completedMeeting(id: completed.id)
  #expect(found.document.id == completed.id)
  #expect((await store.current())?.id == active.id)

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let pointer = try decoder.decode(
    CurrentMeetingPointer.self, from: Data(contentsOf: root.appending(path: "current.json")))
  #expect(pointer.active)
  #expect(pointer.meetingID == active.id)
}

@Test func meetingListRefreshKeepsOtherPendingFinalizationsVisible() {
  let calendar = Calendar(identifier: .gregorian)
  let day = Date(timeIntervalSince1970: 1_768_435_200)
  let completedID = UUID()
  let pendingID = UUID()
  let completed = TodayMeetingSummary(
    id: completedID, title: "Completed", startedAt: day.addingTimeInterval(3_600),
    endedAt: day.addingTimeInterval(4_200), summary: "Done")
  let duplicatePending = TodayMeetingSummary(
    id: completedID, title: "Old pending row", startedAt: completed.startedAt,
    endedAt: completed.endedAt, summary: nil)
  let stillPending = TodayMeetingSummary(
    id: pendingID, title: "Still finalizing", startedAt: day.addingTimeInterval(7_200),
    endedAt: day.addingTimeInterval(7_800), summary: nil)

  let merged = AppModel.mergeMeetingSummaries(
    completed: [completed], pending: [duplicatePending, stillPending], on: day,
    calendar: calendar)

  #expect(merged.map(\.id) == [pendingID, completedID])
}

@Test func persistedMeetingCreatesDurableSyncMarkers() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "Sync marker", calendar: nil)
  let folder = try #require(await store.currentFolder())
  #expect(
    FileManager.default.fileExists(
      atPath: folder.appending(path: RemoteSyncService.folderMarker).path))
  #expect(
    FileManager.default.fileExists(
      atPath: root.appending(path: RemoteSyncService.pointerMarker).path))
}

@Test func emptyStartupFilesAreNotOfferedForRecovery() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "Empty capture", calendar: nil)
  let microphone = try #require(await store.audioURL(named: "microphone.wav"))
  let system = try #require(await store.audioURL(named: "system.wav"))
  try WavFile.finalize(WavFile.create(at: microphone), bytes: 0)
  try WavFile.finalize(WavFile.create(at: system), bytes: 0)
  try await store.setStatus(.failed)
  #expect(await store.latestRecoverableFolder() == nil)
}

@Test func failedMeetingWithSilentAudioRemainsVisibleButIsNotRecoverable() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  let meeting = try await store.begin(title: "Interrupted", calendar: nil)
  let microphone = try #require(await store.audioURL(named: "microphone.wav"))
  let handle = try WavFile.create(at: microphone)
  let silence = Data(repeating: 0, count: 3_200)
  try handle.write(contentsOf: silence)
  try WavFile.finalize(handle, bytes: silence.count)
  try await store.setStatus(.failed)

  #expect(await store.meetingsForDisplay(on: meeting.startedAt).map(\.id) == [meeting.id])
  #expect(await store.latestRecoverableFolder() == nil)
  #expect(await store.recoverableFolder(id: meeting.id) == nil)
}

@Test func recoveryCanTargetASpecificMeeting() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)

  let first = try await store.begin(title: "First interrupted", calendar: nil)
  let firstFolder = try #require(await store.currentFolder())
  let firstHandle = try WavFile.create(at: firstFolder.appending(path: "microphone.wav"))
  let signal = Data(repeating: 1, count: 6_400)
  try firstHandle.write(contentsOf: signal)
  try WavFile.finalize(firstHandle, bytes: signal.count)
  #expect(WavFile.hasMeaningfulSignal(at: firstFolder.appending(path: "microphone.wav")))
  try await store.setStatus(.failed)

  _ = try await store.begin(title: "Second interrupted", calendar: nil)
  let secondFolder = try #require(await store.currentFolder())
  let secondHandle = try WavFile.create(at: secondFolder.appending(path: "microphone.wav"))
  try secondHandle.write(contentsOf: signal)
  try WavFile.finalize(secondHandle, bytes: signal.count)
  #expect(WavFile.hasMeaningfulSignal(at: secondFolder.appending(path: "microphone.wav")))
  try await store.setStatus(.failed)

  let targeted = await store.recoverableFolder(id: first.id)
  let latest = await store.latestRecoverableFolder()
  #expect(targeted?.standardizedFileURL.path == firstFolder.standardizedFileURL.path)
  #expect(latest?.standardizedFileURL.path == secondFolder.standardizedFileURL.path)
}

@Test func activelyManagedMeetingsAreExcludedFromRecovery() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)

  // A meeting that stopped and is still finalizing: status .processing with
  // real audio on disk. It must not be offered for recovery while managed.
  let finalizing = try await store.begin(title: "Finalizing", calendar: nil)
  let finalizingMic = try #require(await store.audioURL(named: "microphone.wav"))
  let finalizingHandle = try WavFile.create(at: finalizingMic)
  let finalizingAudio = Data(repeating: 1, count: 3_200)
  try finalizingHandle.write(contentsOf: finalizingAudio)
  try WavFile.finalize(finalizingHandle, bytes: finalizingAudio.count)
  _ = try await store.prepareForFinalization()

  // A newly started meeting that is actively recording, also with audio.
  let recording = try await store.begin(title: "Recording", calendar: nil)
  let recordingMic = try #require(await store.audioURL(named: "microphone.wav"))
  let recordingHandle = try WavFile.create(at: recordingMic)
  let recordingAudio = Data(repeating: 1, count: 3_200)
  try recordingHandle.write(contentsOf: recordingAudio)
  try WavFile.finalize(recordingHandle, bytes: recordingAudio.count)

  // Without exclusions both look recoverable.
  #expect(await store.latestRecoverableFolder() != nil)
  // Excluding the two managed meetings leaves nothing to recover.
  #expect(
    await store.latestRecoverableFolder(excluding: [finalizing.id, recording.id]) == nil)
}

@Test func completedMeetingsReturnsOnlyTodayNewestFirst() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)

  let first = try await store.begin(title: "First", calendar: nil)
  try await store.replaceTranscript([], status: .complete)
  try await Task.sleep(for: .milliseconds(10))
  let second = try await store.begin(title: "Second", calendar: nil)
  try await store.replaceTranscript([], status: .complete)

  let meetings = await store.completedMeetings(on: Date())
  #expect(Set(meetings.map(\.id)) == Set([second.id, first.id]))
  #expect(
    zip(meetings, meetings.dropFirst()).allSatisfy { newer, older in
      newer.startedAt >= older.startedAt
    })
}

@Test func completedMeetingRenameMovesItsFolderAndUpdatesPointer() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  let calendar = CalendarMetadata(
    eventIdentifier: "event", calendarTitle: "Calendar",
    scheduledStart: Date(), scheduledEnd: Date().addingTimeInterval(3600),
    organizer: MeetingParticipant(name: "Organizer", email: "organizer@example.com"),
    participants: [MeetingParticipant(name: "Participant", email: "participant@example.com")])
  let original = try await store.begin(title: "Original title", calendar: calendar)
  try await store.replaceTranscript(
    [TranscriptTurn(start: 0, end: 1, speaker: "You", text: "Hello", source: .microphone)],
    status: .complete)
  let originalFolder = try #require(await store.currentFolder())

  try await store.renameCompletedMeeting(id: original.id, title: "Renamed meeting")

  #expect(await store.current()?.title == "Renamed meeting")
  #expect(await store.current()?.calendar?.organizer == nil)
  #expect(await store.current()?.calendar?.participants.isEmpty == true)
  let renamedFolder = try #require(await store.currentFolder())
  #expect(renamedFolder.standardizedFileURL.path != originalFolder.standardizedFileURL.path)
  #expect(!FileManager.default.fileExists(atPath: originalFolder.path))
  #expect(renamedFolder.lastPathComponent.contains("-renamed-meeting-"))
  #expect(renamedFolder.lastPathComponent.hasSuffix(String(original.id.uuidString.prefix(8))))
  let meetingMarkdown = try String(
    contentsOf: renamedFolder.appending(path: "meeting.md"), encoding: .utf8)
  let transcriptMarkdown = try String(
    contentsOf: renamedFolder.appending(path: "transcript.md"), encoding: .utf8)
  #expect(meetingMarkdown.contains("# Renamed meeting"))
  #expect(!meetingMarkdown.contains("Organizer"))
  #expect(!meetingMarkdown.contains("participant@example.com"))
  #expect(transcriptMarkdown.contains("# Renamed meeting"))
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let pointer = try decoder.decode(
    CurrentMeetingPointer.self, from: Data(contentsOf: root.appending(path: "current.json")))
  #expect(pointer.title == "Renamed meeting")
  #expect(pointer.relativeFolder.hasSuffix("/\(renamedFolder.lastPathComponent)"))
}

@Test func calendarSuggestionIgnoresBlockAndFocusWords() {
  #expect(CalendarService.shouldIgnore(title: "Focus"))
  #expect(CalendarService.shouldIgnore(title: "Deep focus time"))
  #expect(CalendarService.shouldIgnore(title: "Calendar BLOCK"))
  #expect(CalendarService.shouldIgnore(title: "Focus-time"))
  #expect(CalendarService.shouldIgnore(title: "Lunch with Sam"))
  #expect(!CalendarService.shouldIgnore(title: "Blocker review"))
  #expect(!CalendarService.shouldIgnore(title: "Focusrite demo"))
  #expect(!CalendarService.shouldIgnore(title: "Customer meeting"))
  #expect(!CalendarService.shouldIgnore(title: nil))
}

@Test func ignoredMeetingTitleWordsAreCustomizableAndParseCleanly() {
  #expect(IgnoredMeetingTitlesStore.defaults == ["Block", "Focus", "Lunch"])
  #expect(
    IgnoredMeetingTitlesStore.parse("Block, Focus,,  lunch , Standup\nBlock")
      == ["Block", "Focus", "lunch", "Standup"])
  #expect(CalendarService.shouldIgnore(title: "Team standup", ignoredWords: ["Standup"]))
  #expect(!CalendarService.shouldIgnore(title: "Focus", ignoredWords: ["Standup"]))
  #expect(!CalendarService.shouldIgnore(title: "Anything", ignoredWords: []))
}

@Test func startupNormalizationRepairsFoldersRenamedByOlderBuilds() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "Original title", calendar: nil)
  try await store.replaceTranscript([], status: .complete)
  let originalFolder = try #require(await store.currentFolder())
  let stateURL = originalFolder.appending(path: "meeting.json")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  var document = try decoder.decode(MeetingDocument.self, from: Data(contentsOf: stateURL))
  document.title = "Recovered title"
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try encoder.encode(document).write(to: stateURL, options: .atomic)

  await store.normalizeCompletedMeetingFolders()

  let repairedFolder = try #require(await store.currentFolder())
  #expect(!FileManager.default.fileExists(atPath: originalFolder.path))
  #expect(repairedFolder.lastPathComponent.contains("-recovered-title-"))
  #expect(await store.current()?.title == "Recovered title")
}

@Test func completedMeetingNotesCanBeRecreatedFromStoredState() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  let meeting = try await store.begin(title: "Recoverable notes", calendar: nil)
  try await store.replaceTranscript(
    [TranscriptTurn(start: 0, end: 1, speaker: "You", text: "Stored evidence", source: .microphone)],
    status: .complete)
  let folder = try #require(await store.currentFolder())
  let notesURL = folder.appending(path: "meeting.md")
  try FileManager.default.removeItem(at: notesURL)

  try await store.recreateCompletedMeetingNotes(id: meeting.id)

  let notes = try String(contentsOf: notesURL, encoding: .utf8)
  #expect(notes.contains("# Recoverable notes"))
  #expect(notes.contains("[Open the complete timestamped transcript](transcript.md)"))
}

@Test func vocabularySettingsParseAliasesDeduplicateAndRoundTrip() throws {
  let entries = VocabularySettingsStore.parse(
    "Acme | ack me, acme corp\nAcme Suite\nacme | duplicate")
  #expect(entries.count == 2)
  #expect(entries[0] == VocabularyEntry(term: "Acme", aliases: ["ack me", "acme corp"]))
  #expect(entries[1] == VocabularyEntry(term: "Acme Suite", aliases: []))

  let suite = "MeetingNotesVocabularyTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  VocabularySettingsStore.save(VocabularySettingsStore.formatted(entries), to: defaults)
  #expect(VocabularySettingsStore.load(from: defaults) == entries)
}

@Test func vocabularyCorrectorHandlesPunctuatedAliasesAndCacheInvalidation() {
  let previous = VocabularySettingsStore.loadDraft()
  defer {
    VocabularySettingsStore.save(previous)
    VocabularyTextCorrector.invalidate()
  }

  VocabularySettingsStore.save("Acme | ack me\n.NET | dot net, .net framework")
  VocabularyTextCorrector.invalidate()
  #expect(VocabularyTextCorrector.apply(to: "We use ack me daily") == "We use Acme daily")
  // Aliases starting with a non-word character must still match: a plain \b
  // boundary silently fails for ".net framework".
  #expect(VocabularyTextCorrector.apply(to: "Built on .net framework today") == "Built on .NET today")
  // Whole-word semantics remain for ordinary aliases.
  #expect(VocabularyTextCorrector.apply(to: "backpack meets us") == "backpack meets us")
  #expect(VocabularyTextCorrector.apply(to: "Jack meets us") == "Jack meets us")

  // The compiled patterns are cached until invalidated.
  VocabularySettingsStore.save("Acme | jack")
  #expect(VocabularyTextCorrector.apply(to: "ask jack") == "ask jack")
  VocabularyTextCorrector.invalidate()
  #expect(VocabularyTextCorrector.apply(to: "ask jack") == "ask Acme")
}

@Test func onlyGeneratedMeetingPathsAreAcceptedForRemoteDeletion() {
  // The week layout the app writes today.
  #expect(
    RemoteSyncService.isSafeMeetingPath("2026/W29/2026-07-15/0834-project-atlas-review-3F0A1AEA"))
  // The original layout stays deletable while an archive is still migrating.
  #expect(RemoteSyncService.isSafeMeetingPath("2026/07/15/0834-project-atlas-review-3F0A1AEA"))
  #expect(!RemoteSyncService.isSafeMeetingPath("../../important"))
  #expect(!RemoteSyncService.isSafeMeetingPath("2026/W29/2026-07-15/meeting with spaces"))
  #expect(!RemoteSyncService.isSafeMeetingPath("2026/W29/../etc/passwd"))
  #expect(!RemoteSyncService.isSafeMeetingPath("2026/07/15/meeting with spaces"))
  #expect(!RemoteSyncService.isSafeMeetingPath("2026/07/15"))
}

@Test func transcriptFragmentsMergeIntoReadableTimestampedLines() {
  // Real fragments from a Dutch meeting: the recognizer cut mid-word and lost
  // the space at the seam ("gekre" + "gen", "la" + "ngs gaan").
  let turns = [
    TranscriptTurn(
      start: 29, end: 30, speaker: "Unknown", text: "Johans had de lucht van gekre",
      source: .microphone),
    TranscriptTurn(
      start: 30, end: 31, speaker: "Unknown", text: "gen gedacht<unk> was wij norf la",
      source: .microphone),
    TranscriptTurn(
      start: 31, end: 32, speaker: "Unknown", text: "ngs gaan, kwam even laten",
      source: .microphone),
    TranscriptTurn(
      start: 32, end: 33, speaker: "Unknown", text: "zien hoe wij het dan al doen",
      source: .microphone),
    TranscriptTurn(start: 33, end: 34, speaker: "Unknown", text: ".", source: .microphone),
    // A gap past the merge window starts a new line.
    TranscriptTurn(
      start: 39, end: 40, speaker: "Unknown", text: "Ja, doel was", source: .microphone),
    TranscriptTurn(
      start: 40, end: 41, speaker: "Unknown", text: "vooral een beetje", source: .microphone),
  ]

  let lines = TranscriptFormatter.mergedLines(turns)
  #expect(lines.count == 2)

  // Mid-word splits are repaired rather than left as stutters.
  #expect(lines[0].text.contains("gekregen"))
  #expect(lines[0].text.contains("langs gaan"))
  // The recognizer's unknown-token marker never reaches the file.
  #expect(!lines[0].text.contains("<unk>"))
  // A stray trailing period is attached, not left dangling on its own line.
  #expect(lines[0].text.hasSuffix("."))
  #expect(!lines[0].text.contains(" ."))
  #expect(lines[1].text == "Ja, doel was vooral een beetje")

  // Every line keeps its timestamp so "the last five minutes" stays answerable.
  #expect(lines[0].start == 29)
  #expect(lines[1].start == 39)

  let markdown = TranscriptFormatter.markdown(turns)
  #expect(markdown.contains("**[00:00:29]**"))
  #expect(markdown.contains("**[00:00:39]**"))
  // The placeholder speaker is noise and is never printed.
  #expect(!markdown.contains("Unknown"))

  // The prompt keeps timestamps too, so the model can cite accurate times.
  let prompt = TranscriptFormatter.promptLines(turns)
  #expect(prompt.count == 2)
  #expect(prompt[0].hasPrefix("[00:00:29] "))
  #expect(!prompt.joined().contains("Unknown"))
}

@Test func transcriptRenderingKeepsRealSpeakerNames() {
  // Placeholder labelling is dropped, but a genuine name must still show.
  let turns = [
    TranscriptTurn(start: 0, end: 1, speaker: "André", text: "Goedemorgen", source: .microphone),
    TranscriptTurn(start: 12, end: 13, speaker: "", text: "Hallo", source: .system),
  ]
  let markdown = TranscriptFormatter.markdown(turns)
  #expect(markdown.contains("**[00:00:00] André:** Goedemorgen"))
  // An empty speaker is treated as a placeholder, not printed as a blank label.
  #expect(markdown.contains("**[00:00:12]** Hallo"))
  #expect(!markdown.contains(" :"))
}

@Test func mergingNeverDropsOrReordersTranscriptContent() {
  // Interleaved microphone and system fragments must not be spliced together.
  let turns = [
    TranscriptTurn(start: 0, end: 1, speaker: "Unknown", text: "alpha", source: .microphone),
    TranscriptTurn(start: 1, end: 2, speaker: "Unknown", text: "bravo", source: .system),
    TranscriptTurn(start: 20, end: 21, speaker: "Unknown", text: "charlie", source: .microphone),
  ]
  let text = TranscriptFormatter.mergedLines(turns).map(\.text).joined(separator: " ")
  for word in ["alpha", "bravo", "charlie"] {
    #expect(text.contains(word))
  }
  // Lines are ordered by time regardless of which stream they came from.
  let starts = TranscriptFormatter.mergedLines(turns).map(\.start)
  #expect(starts == starts.sorted())
}

@Test func meetingFoldersAreGroupedByIsoWeek() {
  var components = DateComponents()
  components.year = 2026
  components.month = 7
  components.day = 28
  components.hour = 10
  let calendar = MeetingFolderLayout.isoCalendar
  let date = try! #require(calendar.date(from: components))
  #expect(MeetingFolderLayout.dayPath(for: date) == "2026/W31/2026-07-28")

  // A legacy path keeps its own date; only the grouping changes.
  #expect(
    MeetingFolderLayout.migratedPath(forLegacy: "2026/07/28/1030-review-A1B2C3D4")
      == "2026/W31/2026-07-28/1030-review-A1B2C3D4")

  // Already-migrated paths and junk are left alone.
  #expect(
    MeetingFolderLayout.migratedPath(forLegacy: "2026/W31/2026-07-28/1030-review-A1B2C3D4") == nil)
  #expect(MeetingFolderLayout.migratedPath(forLegacy: "2026/07/28") == nil)

  // Early January belongs to the final ISO week of the previous year, so the
  // week folder must not be split across two year folders.
  var newYear = DateComponents()
  newYear.year = 2027
  newYear.month = 1
  newYear.day = 1
  newYear.hour = 12
  let newYearDate = try! #require(calendar.date(from: newYear))
  #expect(MeetingFolderLayout.dayPath(for: newYearDate) == "2026/W53/2027-01-01")
}

@Test func legacyFoldersMigrateToWeekLayoutWithoutLosingAnything() async throws {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let spool = base.appending(path: "spool")
  let archive = base.appending(path: "archive")
  defer { try? FileManager.default.removeItem(at: base) }
  let manager = FileManager.default

  let sync = RemoteSyncService(
    configuration: .init(
      destination: .local, host: "", path: "", localPath: archive.path, enabled: true))
  let store = MeetingStore(root: spool, sync: sync)

  // A completed meeting written in the original layout, including audio and
  // a transcript, so the move has real content to preserve.
  let legacyFolder = spool.appending(path: "2026/07/15/0834-project-atlas-review-3F0A1AEA")
  try manager.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
  var started = DateComponents()
  started.year = 2026
  started.month = 7
  started.day = 15
  started.hour = 8
  started.minute = 34
  let startedAt = try #require(MeetingFolderLayout.isoCalendar.date(from: started))
  let meetingID = try #require(UUID(uuidString: "3F0A1AEA-1111-2222-3333-444455556666"))
  var document = MeetingDocument(
    id: meetingID, title: "Project Atlas review", startedAt: startedAt,
    status: .complete, transcript: [])
  document.endedAt = startedAt.addingTimeInterval(1_800)
  document.calendar = CalendarMetadata(
    eventIdentifier: "event-1", calendarTitle: "Work",
    scheduledStart: startedAt, scheduledEnd: startedAt.addingTimeInterval(1_800),
    organizer: nil,
    participants: [MeetingParticipant(name: "André Foeken"), MeetingParticipant(name: "Sandra")])
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try encoder.encode(document).write(to: legacyFolder.appending(path: "meeting.json"))
  try Data("# Notes".utf8).write(to: legacyFolder.appending(path: "meeting.md"))
  try Data("00:00 hello".utf8).write(to: legacyFolder.appending(path: "transcript.md"))
  try Data("audio".utf8).write(to: legacyFolder.appending(path: "microphone.wav"))

  let moved = await store.migrateLegacyFolderLayout()
  #expect(moved == 1)

  // Everything moved intact, and the old location is gone rather than duplicated.
  let migrated = spool.appending(path: "2026/W29/2026-07-15/0834-project-atlas-review-3F0A1AEA")
  #expect(manager.fileExists(atPath: migrated.appending(path: "meeting.md").path))
  #expect(manager.fileExists(atPath: migrated.appending(path: "transcript.md").path))
  #expect(manager.fileExists(atPath: migrated.appending(path: "microphone.wav").path))
  #expect(!manager.fileExists(atPath: legacyFolder.path))
  // The empty 2026/07 shell is cleaned up, but the year folder still holds W29.
  #expect(!manager.fileExists(atPath: spool.appending(path: "2026/07").path))

  // Meeting content is untouched, including participants that the rename path
  // would have cleared.
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let reloaded = try decoder.decode(
    MeetingDocument.self, from: Data(contentsOf: migrated.appending(path: "meeting.json")))
  #expect(reloaded.id == meetingID)
  #expect(reloaded.title == "Project Atlas review")
  #expect(reloaded.calendar?.participants.count == 2)
  #expect(try String(contentsOf: migrated.appending(path: "transcript.md")) == "00:00 hello")

  // Running again is a no-op, so an interrupted migration resumes safely.
  let second = await store.migrateLegacyFolderLayout()
  #expect(second == 0)
  #expect(manager.fileExists(atPath: migrated.appending(path: "meeting.json").path))

  // The meeting is still findable by id after the move.
  let (found, foundFolder) = try await store.completedMeeting(id: meetingID)
  #expect(found.title == "Project Atlas review")
  #expect(foundFolder.standardizedFileURL == migrated.standardizedFileURL)
}

@Test func legacyCleanupIgnoresFinderFilesButKeepsRealContent() async throws {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let spool = base.appending(path: "spool")
  defer { try? FileManager.default.removeItem(at: base) }
  let manager = FileManager.default

  let sync = RemoteSyncService(
    configuration: .init(
      destination: .local, host: "", path: "",
      localPath: base.appending(path: "archive").path, enabled: true))
  let store = MeetingStore(root: spool, sync: sync)

  // An emptied day folder that Finder has since littered with .DS_Store.
  let finderLeftover = spool.appending(path: "2026/07/15")
  try manager.createDirectory(at: finderLeftover, withIntermediateDirectories: true)
  try Data("finder".utf8).write(to: finderLeftover.appending(path: ".DS_Store"))

  // A legacy day folder that still holds something real must survive.
  let keepMe = spool.appending(path: "2026/08/03")
  try manager.createDirectory(at: keepMe, withIntermediateDirectories: true)
  try Data("important".utf8).write(to: keepMe.appending(path: "notes.txt"))

  _ = await store.migrateLegacyFolderLayout()

  #expect(!manager.fileExists(atPath: finderLeftover.path))
  #expect(!manager.fileExists(atPath: spool.appending(path: "2026/07").path))
  #expect(manager.fileExists(atPath: keepMe.appending(path: "notes.txt").path))
}

@Test func freshArchiveSettingsAreLocalAndRoundTrip() throws {
  let suite = "MeetingNotesTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  let initial = ArchiveSettingsStore.load(from: defaults)
  #expect(initial.destination == .local)
  #expect(!initial.remoteSyncEnabled)
  #expect(initial.host.isEmpty)
  #expect(
    initial.localPath == "~/Documents/Meetings Notes")
  #expect(initial.postMeetingHookLocation == .disabled)
  #expect(initial.postMeetingHookCommand.isEmpty)
  #expect(initial.httpHookURL.isEmpty)
  // Headers ship prefilled with an example so the expected shape is obvious.
  #expect(
    initial.httpHookHeaders
      == RemoteSyncService.Configuration.defaultHTTPHookHeaders)
  #expect(initial.httpHookHeaders.contains("Authorization: Bearer"))
  #expect(initial.httpHookPayload == .meetingNotes)

  let local = RemoteSyncService.Configuration(
    destination: .local, host: initial.host, path: initial.path,
    localPath: "/tmp/Meeting Notes Archive", enabled: true,
    postMeetingHookLocation: .local,
    postMeetingHookCommand: "meeting-index refresh",
    httpHookURL: "https://example.com/hook",
    httpHookHeaders: "Authorization: Bearer token",
    httpHookPayload: .transcript)
  ArchiveSettingsStore.save(local, to: defaults)
  #expect(ArchiveSettingsStore.load(from: defaults) == local)
}

@Test func httpHookParsesHeadersAndValidatesItsURL() {
  typealias Configuration = RemoteSyncService.Configuration

  let headers = Configuration.parseHookHeaders(
    """
    Authorization: Bearer abc123
    # a comment line is ignored

    X-Source:  Meeting Notes
    not-a-header
    Empty:
    """)
  #expect(headers.count == 2)
  #expect(headers[0] == Configuration.HTTPHookHeader(name: "Authorization", value: "Bearer abc123"))
  // Surrounding whitespace is trimmed from both sides of the colon.
  #expect(headers[1] == Configuration.HTTPHookHeader(name: "X-Source", value: "Meeting Notes"))

  // An empty URL means the hook is simply off, not misconfigured.
  #expect(Configuration.httpHookURLError("") == nil)
  #expect(Configuration.httpHookURLError("https://example.com/hook") == nil)
  #expect(Configuration.httpHookURLError("http://localhost:8080/hook") == nil)
  #expect(Configuration.httpHookURLError("example.com/hook") != nil)
  #expect(Configuration.httpHookURLError("ftp://example.com") != nil)

  var configuration = Configuration.defaults
  configuration.httpHookURL = "not a url"
  #expect(configuration.validationError != nil)
  configuration.httpHookURL = "https://example.com/hook"
  #expect(configuration.validationError == nil)

  #expect(Configuration.HookPayload.meetingNotes.fileName == "meeting.md")
  #expect(Configuration.HookPayload.transcript.fileName == "transcript.md")
}

@Test func httpHookAlwaysSendsMeetingMetadataHeaders() {
  let started = Date(timeIntervalSince1970: 1_767_268_800)
  var meeting = MeetingDocument(
    id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
    title: "Portfolio review",
    startedAt: started,
    status: .complete,
    transcript: [])
  meeting.endedAt = started.addingTimeInterval(1_800)
  meeting.calendar = CalendarMetadata(
    eventIdentifier: "event-1",
    calendarTitle: "Work",
    scheduledStart: started,
    scheduledEnd: started.addingTimeInterval(1_800),
    organizer: nil,
    participants: [
      MeetingParticipant(name: "Andre Foeken"),
      MeetingParticipant(name: "Sandra"),
    ])

  let headers = Dictionary(
    uniqueKeysWithValues: RemoteSyncService.metadataHeaders(
      fileName: "meeting.md",
      meetingPath: "2026/01/01/1030-portfolio-review-12345678",
      meeting: meeting))

  #expect(headers["X-Meeting-Notes-File"] == "meeting.md")
  #expect(headers["X-Meeting-Notes-Folder"] == "2026/01/01/1030-portfolio-review-12345678")
  #expect(headers["X-Meeting-Notes-Id"] == "12345678-1234-1234-1234-123456789ABC")
  #expect(headers["X-Meeting-Notes-Title"] == "Portfolio review")
  #expect(headers["X-Meeting-Notes-Duration-Seconds"] == "1800")
  #expect(headers["X-Meeting-Notes-Participants"] == "Andre Foeken, Sandra")
  #expect(headers["X-Meeting-Notes-Started-At"]?.hasPrefix("2026-01-01") == true)

  // A test request has no meeting yet, so only the file name is known.
  let testHeaders = Dictionary(
    uniqueKeysWithValues: RemoteSyncService.metadataHeaders(
      fileName: "transcript.md", meetingPath: nil, meeting: nil))
  #expect(testHeaders["X-Meeting-Notes-File"] == "transcript.md")
  #expect(testHeaders["X-Meeting-Notes-Id"] == nil)

  // Header values stay single-line and ASCII-safe.
  #expect(RemoteSyncService.sanitizedHeaderValue("Line one\nLine two") == "Line one Line two")
  #expect(RemoteSyncService.sanitizedHeaderValue("Café ☕").contains("%") == true)
}

@Test func archiveHookAllowsAnEmptyCommandAndRequiresRemoteSyncWhenActive() {
  var configuration = RemoteSyncService.Configuration.defaults
  configuration.postMeetingHookLocation = .local
  #expect(configuration.validationError == nil)

  configuration.postMeetingHookLocation = .remote
  #expect(configuration.validationError == nil)

  configuration.postMeetingHookCommand = "meeting-index refresh"
  #expect(
    configuration.validationError
      == "Enable remote sync before running the hook on the remote server.")
}

@Test func legacyRemoteArchiveMigratesToLocalFirstStorage() throws {
  let suite = "MeetingNotesLegacyArchiveTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("remote", forKey: "archive.destination")
  defaults.set("archive.example.com", forKey: "archive.remoteHost")
  defaults.set("~/MeetingNotes", forKey: "archive.remotePath")
  defaults.set("~/MeetingNotes", forKey: "archive.localPath")

  let migrated = ArchiveSettingsStore.load(from: defaults)
  #expect(migrated.remoteSyncEnabled)
  #expect(migrated.host == "archive.example.com")
  #expect(migrated.path == "~/MeetingNotes")
  #expect(migrated.localPath == RemoteSyncService.Configuration.defaultLocalPath)

  ArchiveSettingsStore.save(migrated, to: defaults)
  #expect(defaults.bool(forKey: "archive.remoteEnabled"))
  #expect(ArchiveSettingsStore.load(from: defaults) == migrated)
}

@Test func tanaSettingsAreOptInAndGraphSpecific() throws {
  let suite = "MeetingNotesTanaTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(TanaSettingsStore.load(from: defaults) == .defaults)
  let settings = TanaSettings(
    enabled: true,
    workspaceID: "workspace-1",
    workspaceName: "My graph",
    selectedSupertagIDs: ["person", "project"])
  TanaSettingsStore.save(settings, to: defaults)
  #expect(TanaSettingsStore.load(from: defaults) == settings)
}

@Test func tanaEntityMatcherFindsLikelyMisrecognizedNamesWithoutDumpingTheGraph() {
  let meeting = MeetingDocument(
    id: UUID(), title: "Weekly meeting", startedAt: Date(), status: .complete,
    transcript: [
      TranscriptTurn(
        start: 0, end: 2, speaker: "You",
        text: "Jami will review the Atlas proposal tomorrow.", source: .microphone)
    ])

  let matches = TanaEntityMatcher.relevantNames(
    from: ["Jamie", "Atlas", "Completely Unrelated Person"], meeting: meeting)
  #expect(matches.contains("Jamie"))
  #expect(matches.contains("Atlas"))
  #expect(!matches.contains("Completely Unrelated Person"))
}

@Test func tanaEntityMatcherDoesNotExpandBareOrDifferentNamesIntoPeople() {
  let meeting = MeetingDocument(
    id: UUID(), title: "Atlas", startedAt: Date(), status: .complete,
    transcript: [
      TranscriptTurn(
        start: 0, end: 2, speaker: "Unknown",
        text: "Alex Parker raised this with Sam.", source: .microphone)
    ])

  let matches = TanaEntityMatcher.relevantNames(
    from: ["Alex Morgan", "Alex Parker", "Samantha Rivera"], meeting: meeting)
  #expect(matches == ["Alex Parker"])
}

@Test func tanaEntityMatcherRequiresGivenAndFamilyNameEvidenceForFullIdentity() {
  let meeting = MeetingDocument(
    id: UUID(), title: "Recruitment", startedAt: Date(), status: .complete,
    transcript: [
      TranscriptTurn(
        start: 0, end: 2, speaker: "Unknown",
        text: "Samantha Rivera explained the constraint.", source: .microphone)
    ])

  let matches = TanaEntityMatcher.relevantNames(
    from: ["Samantha Rivera", "Taylor Chen"], meeting: meeting)
  #expect(matches == ["Samantha Rivera"])
}

@Test func tanaEntityMatcherSuppressesAmbiguousFuzzySingleNames() {
  let meeting = MeetingDocument(
    id: UUID(), title: "Weekly", startedAt: Date(), status: .complete,
    transcript: [
      TranscriptTurn(
        start: 0, end: 2, speaker: "Unknown",
        text: "Jamey joined the discussion.", source: .microphone)
    ])

  let matches = TanaEntityMatcher.relevantNames(
    from: ["Jamie", "Jaymie"], meeting: meeting)
  #expect(matches.isEmpty)
}

@Test func tanaSupertagChoicesGroupDuplicateVisibleNamesWithoutLosingIDs() {
  let choices = TanaSupertagChoice.grouped([
    TanaSupertag(id: "team-a", name: "team", color: nil),
    TanaSupertag(id: "team-b", name: " Team ", color: "blue"),
    TanaSupertag(id: "person", name: "Person", color: nil),
  ])

  #expect(choices.map(\.name) == ["Person", "team"])
  #expect(choices.first(where: { $0.id == "team" })?.tagIDs == ["team-a", "team-b"])
}

@Test func tanaSupertagChoicesPutSelectedGroupsFirst() {
  let choices = TanaSupertagChoice.grouped([
    TanaSupertag(id: "company", name: "Company", color: nil),
    TanaSupertag(id: "person-a", name: "Person", color: nil),
    TanaSupertag(id: "person-b", name: " person ", color: nil),
    TanaSupertag(id: "project", name: "Project", color: nil),
    TanaSupertag(id: "team", name: "Team", color: nil),
  ])

  let sorted = TanaSupertagChoice.selectedFirst(
    choices, selectedTagIDs: ["team", "person-b"])

  #expect(sorted.map(\.name) == ["Person", "Team", "Company", "Project"])
}

@Test func audioRetentionDefaultsOffAndRoundTrips() throws {
  let suite = "MeetingNotesAudioRetentionTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(!AudioRetentionSettingsStore.load(from: defaults))
  AudioRetentionSettingsStore.save(true, to: defaults)
  #expect(AudioRetentionSettingsStore.load(from: defaults))
  AudioRetentionSettingsStore.save(false, to: defaults)
  #expect(!AudioRetentionSettingsStore.load(from: defaults))
}

@Test func transcriptRetentionDefaultsToNinetyDaysAndCanBeDisabled() throws {
  let suite = "MeetingNotesTranscriptRetentionTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(
    TranscriptRetentionSettingsStore.load(from: defaults)
      == TranscriptRetentionSettings(enabled: true, days: 90))
  TranscriptRetentionSettingsStore.save(
    TranscriptRetentionSettings(enabled: false, days: 30), to: defaults)
  #expect(
    TranscriptRetentionSettingsStore.load(from: defaults)
      == TranscriptRetentionSettings(enabled: false, days: 30))
}

@Test func meetingNotesLanguageDefaultsToTranscriptAndRoundTrips() throws {
  let suite = "MeetingNotesLanguageTests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }

  #expect(MeetingNotesLanguageStore.load(from: defaults) == .source)
  #expect(MeetingNotesLanguage.source.processingInstruction.contains("predominant language"))
  MeetingNotesLanguageStore.save(.dutch, to: defaults)
  #expect(MeetingNotesLanguageStore.load(from: defaults) == .dutch)
  #expect(MeetingNotesLanguage.dutch.processingInstruction.contains("Dutch"))
}

@Test func expiredTranscriptAndAudioArePurgedButStructuredNoteRemains() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sync = RemoteSyncService(configuration: .init(host: "", path: "", enabled: false))
  let store = MeetingStore(root: root, sync: sync)
  _ = try await store.begin(title: "Old meeting", calendar: nil)
  try await store.replaceTranscript(
    [TranscriptTurn(
      start: 0, end: 1, speaker: "You", text: "Sensitive exact words", source: .microphone)],
    status: .complete)
  let folder = try #require(await store.currentFolder())
  try Data("retained audio".utf8).write(to: folder.appending(path: "microphone.wav"))

  var oldMeeting = try #require(await store.current())
  oldMeeting.endedAt = Date(timeIntervalSinceNow: -120 * 86_400)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  try encoder.encode(oldMeeting).write(to: folder.appending(path: "meeting.json"), options: .atomic)

  let now = Date()
  let cutoff = try #require(Calendar.current.date(byAdding: .day, value: -90, to: now))
  #expect(try await store.purgeExpiredTranscripts(before: cutoff, now: now) == 1)

  #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "transcript.md").path))
  #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "microphone.wav").path))
  #expect(FileManager.default.fileExists(atPath: folder.appending(path: "meeting.md").path))

  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let retained = try decoder.decode(
    MeetingDocument.self, from: Data(contentsOf: folder.appending(path: "meeting.json")))
  #expect(retained.transcript.isEmpty)
  #expect(retained.transcriptDeletedAt != nil)
  let note = try String(contentsOf: folder.appending(path: "meeting.md"), encoding: .utf8)
  #expect(note.contains("Deleted according to the retention policy"))
  #expect(!note.contains("(transcript.md)"))

  let retainedID = retained.id
  try await store.renameCompletedMeeting(id: retainedID, title: "Renamed old meeting")
  let renamedFolder = try #require(await store.currentFolder())
  #expect(!FileManager.default.fileExists(atPath: renamedFolder.appending(path: "transcript.md").path))
}

@Test func localArchiveSyncExcludesAudioAndCopiesLivePointer() async throws {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let spool = base.appending(path: "spool")
  let archive = base.appending(path: "archive")
  defer { try? FileManager.default.removeItem(at: base) }
  let sync = RemoteSyncService(
    configuration: .init(
      destination: .local, host: "", path: "", localPath: archive.path, enabled: true))
  let store = MeetingStore(root: spool, sync: sync)
  _ = try await store.begin(title: "Local archive", calendar: nil)
  let folder = try #require(await store.currentFolder())
  try Data("private audio".utf8).write(to: folder.appending(path: "microphone.wav"))

  await sync.enqueue(folder: folder)
  await sync.enqueuePointer(spool.appending(path: "current.json"))
  await sync.flush()

  let relative = folder.pathComponents.suffix(4).joined(separator: "/")
  let archived = archive.appending(path: relative)
  #expect(FileManager.default.fileExists(atPath: archived.appending(path: "live.md").path))
  #expect(FileManager.default.fileExists(atPath: archived.appending(path: "meeting.json").path))
  #expect(!FileManager.default.fileExists(atPath: archived.appending(path: "microphone.wav").path))
  #expect(FileManager.default.fileExists(atPath: archive.appending(path: "current.json").path))
}

@Test func localArchiveSyncIncludesAudioWhenRetentionIsEnabled() async throws {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let spool = base.appending(path: "spool")
  let archive = base.appending(path: "archive")
  defer { try? FileManager.default.removeItem(at: base) }
  let sync = RemoteSyncService(
    configuration: .init(
      destination: .local, host: "", path: "", localPath: archive.path, enabled: true,
      includeAudio: true))
  let store = MeetingStore(root: spool, sync: sync)
  _ = try await store.begin(title: "Retained audio", calendar: nil)
  let folder = try #require(await store.currentFolder())
  var sourceAudio = folder.appending(path: "microphone.wav")
  try Data("private audio".utf8).write(to: sourceAudio)
  var hiddenValues = URLResourceValues()
  hiddenValues.isHidden = true
  try sourceAudio.setResourceValues(hiddenValues)

  await sync.enqueue(folder: folder)
  await sync.flush()

  let relative = folder.pathComponents.suffix(4).joined(separator: "/")
  let archived = archive.appending(path: relative)
  let archivedAudio = archived.appending(path: "microphone.wav")
  #expect(FileManager.default.fileExists(atPath: archivedAudio.path))
  #expect(try archivedAudio.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
}
