import AVFoundation
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  enum State: Equatable {
    case idle
    case starting
    case recording
    case paused
    case processing
    case failed(String)
  }

  enum StatusSeverity: Equatable {
    case info
    case warning
    case error
  }

  var state: State = .idle
  var title = ""
  var elapsed: TimeInterval = 0
  var recentTurns: [TranscriptTurn] = []
  var statusText = "Ready" {
    didSet { statusSeverity = .info }
  }
  /// Set immediately after `statusText` at call sites that report a problem;
  /// every plain `statusText` assignment resets this to `.info`.
  var statusSeverity: StatusSeverity = .info
  var chatGPTAuthenticated = false
  var chatGPTAuthInProgress = false
  var chatGPTAuthStatusText = "Checking sign-in…"
  var recoverableMeetingAvailable = false
  var enrichmentRetryAvailable = false
  var displayedMeetings: [TodayMeetingSummary] = []
  var selectedMeetingDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
  /// True while the meeting list is meant to show "today". Midnight and wake
  /// then advance the list automatically; an explicit visit to an older day
  /// stays put until the user navigates back.
  private var followsCurrentDay = true
  var meetingPendingDeletion: TodayMeetingSummary?
  var meetingPendingRename: TodayMeetingSummary?
  var meetingRenameDraft = ""
  var remoteSyncEnabled = false
  var remoteHostDraft = RemoteSyncService.Configuration.defaults.host
  var remotePathDraft = RemoteSyncService.Configuration.defaults.path
  var localArchivePathDraft = RemoteSyncService.Configuration.defaults.localPath
  var postMeetingHookLocation = RemoteSyncService.Configuration.defaults.postMeetingHookLocation
  var postMeetingHookCommand = RemoteSyncService.Configuration.defaults.postMeetingHookCommand
  var httpHookURLDraft = RemoteSyncService.Configuration.defaults.httpHookURL
  var httpHookHeadersDraft = RemoteSyncService.Configuration.defaults.httpHookHeaders
  var httpHookPayload = RemoteSyncService.Configuration.defaults.httpHookPayload
  var httpHookStatusText = ""
  var settingsStatusText = ""
  var hookSettingsStatusText = ""
  var vocabularyEntries = VocabularySettingsStore.load()
  var vocabularyTermDraft = ""
  var vocabularyMishearingDraft = ""
  var vocabularyStatusText = ""
  var keepAudioAfterProcessing = AudioRetentionSettingsStore.load()
  var useSystemDefaultMicrophone = MicrophoneSettingsStore.useSystemDefault()
  var microphoneDevices = MicrophoneSettingsStore.devices()
  var meetingDetectionEnabled = MeetingDetectionSettingsStore.load()
  var detectedMeetingApp: String?
  var removeFillerWords = FillerWordSettingsStore.load()
  var meetingNotesLanguage = MeetingNotesLanguageStore.load()
  var ignoredMeetingTitlesDraft = IgnoredMeetingTitlesStore.load().joined(separator: ", ")
  var updateChannel = UpdateChannelSettingsStore.load()
  var automaticTranscriptDeletionEnabled = true
  var transcriptRetentionDays = TranscriptRetentionSettings.defaultDays
  var transcriptRetentionStatusText = ""
  var tanaEnabled = false
  var tanaConnected = false
  var tanaConnectionInProgress = false
  var tanaStatusText = ""
  var tanaWorkspaces: [TanaWorkspace] = []
  var tanaWorkspaceID = ""
  var tanaWorkspaceName = ""
  var tanaSupertags: [TanaSupertag] = []
  var tanaSelectedSupertagIDs: Set<String> = []
  var codexLaunchingMeetingID: UUID?
  var codexLaunchingCurrentMeeting = false
  var codexPromptDraft = CodexPromptSettingsStore.load()
  var codexPromptStatusText = ""
  var codexSummaryMessageDraft = CodexPromptSettingsStore.loadSummaryMessage()
  var codexSummaryMessageEnabled = CodexPromptSettingsStore.summaryMessageEnabled()
  var codexSummaryMessageStatusText = ""
  var codexAutoCreateThreads = CodexPromptSettingsStore.autoCreateThreads()

  var tanaSupertagChoices: [TanaSupertagChoice] {
    TanaSupertagChoice.selectedFirst(
      TanaSupertagChoice.grouped(tanaSupertags),
      selectedTagIDs: tanaSelectedSupertagIDs)
  }

  private let calendar = CalendarService()
  private let remoteSync: RemoteSyncService
  private let root: URL
  private let store: MeetingStore
  private let microphone = MicrophoneRecorder()
  private let systemAudio = SystemAudioRecorder()
  private let transcriber = NemotronTranscriber()
  private let live: LiveTranscriptionEngine
  private let final: FinalTranscriptionEngine
  private let enricher = OpenAIEnricher()
  private let captureClock = CaptureClock()
  private let recordingWakeLock = RecordingWakeLock()
  private let meetingActivityMonitor = MeetingActivityMonitor()
  private let meetingAutoStopScheduler = MeetingAutoStopScheduler()
  private let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
  private let isMaintenance = ProcessInfo.processInfo.arguments.contains("--repair-meeting")
    || ProcessInfo.processInfo.arguments.contains("--regenerate-insights")
  private var timer: Timer?
  private var startedAt: Date?
  private var lastHeartbeatElapsed: TimeInterval = 0
  private var pausedBySleep = false
  private var liveFeedTask: Task<Void, Never>?
  private var liveFeedContinuation:
    AsyncStream<(samples: [Int16], source: TranscriptTurn.Source, wavPosition: Int)>.Continuation?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var calendarMetadata: CalendarMetadata?
  private var retentionMaintenanceTask: Task<Void, Never>?
  private var deferredNotesMaintenanceTask: Task<Void, Never>?
  private var transientStatusTask: Task<Void, Never>?
  private var archiveSettingsSaveTask: Task<Void, Never>?
  private var hookSettingsSaveTask: Task<Void, Never>?
  private var httpHookSaveTask: Task<Void, Never>?
  private var latestDetectedMeetingApp: String?
  private var recordingMeetingApp: String?
  private var stoppedMeetingFinalizationTasks: [UUID: Task<Void, Never>] = [:]
  private var stoppedMeetingGracePeriods: Set<UUID> = []
  private var pendingMeetingSummaries: [UUID: TodayMeetingSummary] = [:]
  private var activeRecordingMeetingID: UUID?

  init() {
    let archiveConfiguration = ArchiveSettingsStore.load()
    root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "MeetingNotes/Spool", directoryHint: .isDirectory)
    remoteSync = RemoteSyncService(configuration: archiveConfiguration)
    store = MeetingStore(root: root, sync: remoteSync)
    live = LiveTranscriptionEngine(transcriber: transcriber)
    final = FinalTranscriptionEngine(transcriber: transcriber)
    remoteSyncEnabled = archiveConfiguration.remoteSyncEnabled
    remoteHostDraft = archiveConfiguration.host
    remotePathDraft = archiveConfiguration.path
    localArchivePathDraft = archiveConfiguration.localPath
    postMeetingHookLocation = archiveConfiguration.postMeetingHookLocation
    postMeetingHookCommand = archiveConfiguration.postMeetingHookCommand
    httpHookURLDraft = archiveConfiguration.httpHookURL
    httpHookHeadersDraft = archiveConfiguration.httpHookHeaders
    httpHookPayload = archiveConfiguration.httpHookPayload
    let transcriptRetention = TranscriptRetentionSettingsStore.load()
    automaticTranscriptDeletionEnabled = transcriptRetention.enabled
    transcriptRetentionDays = transcriptRetention.days
    let tanaSettings = TanaSettingsStore.load()
    tanaEnabled = tanaSettings.enabled
    tanaWorkspaceID = tanaSettings.workspaceID ?? ""
    tanaWorkspaceName = tanaSettings.workspaceName ?? ""
    tanaSelectedSupertagIDs = tanaSettings.selectedSupertagIDs
    Task { [transcriber] in try? await transcriber.prepare() }
    let notifications = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      notifications.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleWillSleep() }
      })
    workspaceObservers.append(
      notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main)
      { [weak self] _ in
        Task { @MainActor in self?.didWake() }
      })
    // The system posts this at midnight, on time-zone changes, and after
    // clock adjustments. Sleeping through midnight can swallow it, so wake
    // also re-checks the day below.
    workspaceObservers.append(
      NotificationCenter.default.addObserver(
        forName: .NSCalendarDayChanged, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.handleDayChange() }
      })
    if !isUITest && !isMaintenance {
      MeetingNotificationService.shared.onStartRecording = { [weak self] in
        self?.recordDetectedMeeting()
      }
      MeetingNotificationService.shared.onDismiss = { [weak self] in
        self?.dismissDetectedMeeting()
      }
      meetingActivityMonitor.onDetectedAppChanged = { [weak self] app in
        self?.handleDetectedMeetingApp(app)
      }
      if meetingDetectionEnabled { meetingActivityMonitor.start() }
      Task { [weak self] in await self?.loadInitialState() }
    }
  }

  func setMeetingDetectionEnabled(_ enabled: Bool) {
    guard meetingDetectionEnabled != enabled else { return }
    meetingDetectionEnabled = enabled
    MeetingDetectionSettingsStore.save(enabled)
    if enabled {
      meetingActivityMonitor.start()
    } else {
      meetingActivityMonitor.stop()
      detectedMeetingApp = nil
    }
  }

  func persistIgnoredMeetingTitles() {
    IgnoredMeetingTitlesStore.save(IgnoredMeetingTitlesStore.parse(ignoredMeetingTitlesDraft))
  }

  func persistCodexPromptDraft() {
    guard !codexPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      codexPromptStatusText = "The prompt cannot be empty."
      return
    }
    CodexPromptSettingsStore.save(codexPromptDraft)
    if codexPromptStatusText == "The prompt cannot be empty." {
      codexPromptStatusText = ""
    }
  }

  func restoreDefaultCodexPrompt() {
    codexPromptDraft = CodexPromptSettingsStore.restoreDefault()
    codexPromptStatusText = "Default prompt restored."
  }

  func persistCodexSummaryMessageDraft() {
    CodexPromptSettingsStore.saveSummaryMessage(codexSummaryMessageDraft)
    codexSummaryMessageStatusText = ""
  }

  func setCodexSummaryMessageEnabled(_ enabled: Bool) {
    guard codexSummaryMessageEnabled != enabled else { return }
    codexSummaryMessageEnabled = enabled
    CodexPromptSettingsStore.saveSummaryMessageEnabled(enabled)
  }

  func setCodexAutoCreateThreads(_ enabled: Bool) {
    guard codexAutoCreateThreads != enabled else { return }
    codexAutoCreateThreads = enabled
    CodexPromptSettingsStore.saveAutoCreateThreads(enabled)
  }

  func setRemoveFillerWords(_ enabled: Bool) {
    guard removeFillerWords != enabled else { return }
    removeFillerWords = enabled
    FillerWordSettingsStore.save(enabled)
    vocabularyStatusText = enabled ? "Filler word removal enabled" : "Filler word removal disabled"
  }

  func setMeetingNotesLanguage(_ language: MeetingNotesLanguage) {
    guard meetingNotesLanguage != language else { return }
    meetingNotesLanguage = language
    MeetingNotesLanguageStore.save(language)
    showTransientStatus(
      language == .source
        ? "Meeting notes will follow the transcript language"
        : "Meeting notes will be written in \(language.label)")
  }

  /// Sparkle reads the stored channel on every check, so no relaunch is
  /// needed. Moving back to stable never downgrades an already-installed beta.
  func setUpdateChannel(_ channel: UpdateChannel) {
    guard updateChannel != channel else { return }
    updateChannel = channel
    UpdateChannelSettingsStore.save(channel)
    showTransientStatus(
      channel == .beta
        ? "Updates will include beta builds"
        : "Updates will follow stable releases only")
  }

  func dismissDetectedMeeting() {
    detectedMeetingApp = nil
    MeetingNotificationService.shared.suppressCurrentMeeting()
    if state == .idle { statusText = "Ready" }
  }

  func recordDetectedMeeting() {
    guard state == .idle else { return }
    let app = detectedMeetingApp
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let app
    {
      title = "\(app) meeting"
    }
    recordingMeetingApp = app
    detectedMeetingApp = nil
    MeetingNotificationService.shared.suppressCurrentMeeting()
    Task { await start() }
  }

  private func handleDetectedMeetingApp(_ app: String?) {
    latestDetectedMeetingApp = app
    updateMeetingAutoStop()
    if app == nil {
      MeetingNotificationService.shared.meetingEnded()
      guard state == .idle else { return }
      detectedMeetingApp = nil
      if statusText.hasSuffix(" meeting detected") { statusText = "Ready" }
      return
    }

    guard state == .idle else { return }
    detectedMeetingApp = app
    if let app {
      statusText = "\(app) meeting detected"
      MeetingNotificationService.shared.showDetectedMeeting(app: app)
    }
  }

  func loadInitialState() async {
    guard !isUITest else { return }
    await store.normalizeCompletedMeetingFolders()
    await store.normalizeMeetingDocuments()
    await remoteSync.reconcile(root: root)
    await runTranscriptRetentionCleanup(reportStatus: false)
    startRetentionMaintenance()
    await refreshRecoverableMeetingAvailability()
    await refreshMeetingDay()
    await loadCalendarSuggestion()
    await refreshChatGPTAuthentication()
    await runDeferredNotesMaintenance(reportStatus: false)
    startDeferredNotesMaintenance()
    if tanaEnabled { await refreshTanaConnection() }
  }

  func repairCompletedMeeting(at targetFolder: URL) async throws {
    let spool = root.standardizedFileURL.path
    let target = targetFolder.standardizedFileURL
    guard target.path.hasPrefix(spool + "/") else {
      throw NSError(
        domain: "MeetingNotes", code: 8,
        userInfo: [NSLocalizedDescriptionKey: "The repair target is outside the private spool"])
    }
    let document = try await store.load(folder: target)
    let microphoneURL = target.appending(path: "microphone.wav")
    let systemURL = target.appending(path: "system.wav")
    for url in [microphoneURL, systemURL]
    where FileManager.default.fileExists(atPath: url.path) {
      try WavFile.repairHeader(at: url)
    }
    let turns = try await final.process(microphone: microphoneURL, system: systemURL)
    if document.status == .complete {
      try await store.replaceCompletedTranscript(turns)
    } else {
      try await store.setFinalTranscript(turns)
      var insights: MeetingInsights?
      if let meeting = await store.current() {
        let checkpoint = target.appending(path: "enrichment-checkpoint.json")
        insights = try? await enricher.enrich(meeting, checkpointURL: checkpoint)
      }
      try await store.finalize(insights: insights)
      if !AudioRetentionSettingsStore.load() { try await store.removeAudioFiles() }
    }
    await remoteSync.flush()
    if let syncError = await remoteSync.lastError {
      throw NSError(
        domain: "MeetingNotes", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Transcript repaired locally; sync failed: \(syncError)"])
    }
  }

  func regenerateMeetingInsights(at targetFolder: URL) async throws {
    let spool = root.standardizedFileURL.path
    let target = targetFolder.standardizedFileURL
    guard target.path.hasPrefix(spool + "/") else {
      throw NSError(
        domain: "MeetingNotes", code: 10,
        userInfo: [NSLocalizedDescriptionKey: "The insights target is outside the private spool"])
    }
    let meeting = try await store.load(folder: target)
    guard meeting.status == .complete, !meeting.transcript.isEmpty else {
      throw NSError(
        domain: "MeetingNotes", code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Only a completed meeting with a transcript can be enriched"])
    }
    let insights = try await enricher.enrich(
      meeting, checkpointURL: target.appending(path: "enrichment-checkpoint.json"))
    try await store.setInsights(insights)
    await remoteSync.flush()
    if let syncError = await remoteSync.lastError {
      throw NSError(
        domain: "MeetingNotes", code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Insights saved locally; sync failed: \(syncError)"])
    }
  }

  func refreshChatGPTAuthentication() async {
    chatGPTAuthenticated = await ChatGPTAuthService.shared.isAuthenticated()
    chatGPTAuthStatusText = chatGPTAuthenticated
      ? "Signed in with ChatGPT"
      : "Sign in to generate structured meeting notes."
  }

  func signInToChatGPT() {
    guard !chatGPTAuthInProgress else { return }
    chatGPTAuthInProgress = true
    chatGPTAuthStatusText = "Complete sign-in in your browser…"
    Task {
      do {
        try await ChatGPTAuthService.shared.signIn()
        await refreshChatGPTAuthentication()
      } catch {
        chatGPTAuthenticated = false
        chatGPTAuthStatusText = error.localizedDescription
      }
      chatGPTAuthInProgress = false
    }
  }

  func signOutOfChatGPT() {
    guard !chatGPTAuthInProgress else { return }
    chatGPTAuthInProgress = true
    Task {
      do {
        try await ChatGPTAuthService.shared.signOut()
        chatGPTAuthenticated = false
        chatGPTAuthStatusText = "Signed out of ChatGPT"
      } catch {
        chatGPTAuthStatusText = error.localizedDescription
      }
      chatGPTAuthInProgress = false
    }
  }

  func setTanaEnabled(_ enabled: Bool) {
    tanaEnabled = enabled
    saveTanaSettings()
    if enabled {
      Task { await refreshTanaConnection() }
    } else {
      tanaStatusText = "Tana enrichment is off"
    }
  }

  func connectTana() {
    guard !tanaConnectionInProgress else { return }
    tanaConnectionInProgress = true
    tanaStatusText = "Approve access in Tana Outliner…"
    Task {
      do {
        try await TanaOAuthService.shared.signIn()
        tanaConnected = true
        tanaStatusText = "Connected to Tana"
        try await loadTanaWorkspacesAndTags()
      } catch {
        tanaConnected = false
        tanaStatusText = error.localizedDescription
      }
      tanaConnectionInProgress = false
    }
  }

  func disconnectTana() {
    TanaOAuthService.shared.signOut()
    tanaConnected = false
    tanaWorkspaces = []
    tanaSupertags = []
    tanaStatusText = "Disconnected from Tana"
  }

  func selectTanaWorkspace(_ workspaceID: String) {
    guard tanaWorkspaceID != workspaceID else { return }
    tanaWorkspaceID = workspaceID
    tanaWorkspaceName = tanaWorkspaces.first(where: { $0.id == workspaceID })?.name ?? ""
    tanaSelectedSupertagIDs = []
    tanaSupertags = []
    saveTanaSettings()
    Task {
      do {
        tanaSupertags = try await TanaAPIClient.shared.supertags(workspaceID: workspaceID)
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tanaStatusText = "Choose the Supertags Meeting Notes may use"
      } catch {
        tanaStatusText = error.localizedDescription
      }
    }
  }

  func isTanaSupertagSelected(_ choice: TanaSupertagChoice) -> Bool {
    !tanaSelectedSupertagIDs.isDisjoint(with: choice.tagIDs)
  }

  func setTanaSupertag(_ choice: TanaSupertagChoice, selected: Bool) {
    if selected { tanaSelectedSupertagIDs.formUnion(choice.tagIDs) }
    else { tanaSelectedSupertagIDs.subtract(choice.tagIDs) }
    saveTanaSettings()
    let count = tanaSupertagChoices.filter(isTanaSupertagSelected).count
    tanaStatusText = count == 0 ? "No Supertags selected" : "\(count) Supertag\(count == 1 ? "" : "s") selected"
  }

  func refreshTanaConnection() async {
    tanaConnected = TanaOAuthService.shared.isConnected
    guard tanaConnected else {
      tanaStatusText = "Connect to choose a graph and Supertags"
      return
    }
    do {
      try await loadTanaWorkspacesAndTags()
      tanaStatusText = "Connected to Tana"
    } catch {
      tanaStatusText = error.localizedDescription
    }
  }

  private func loadTanaWorkspacesAndTags() async throws {
    tanaWorkspaces = try await TanaAPIClient.shared.workspaces()
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    guard !tanaWorkspaceID.isEmpty else {
      tanaSupertags = []
      return
    }
    guard tanaWorkspaces.contains(where: { $0.id == tanaWorkspaceID }) else {
      tanaSupertags = []
      let name = tanaWorkspaceName.isEmpty ? "the selected workspace" : tanaWorkspaceName
      tanaStatusText = "Open \(name) in Tana Outliner to make its Supertags available"
      return
    }
    tanaSupertags = try await TanaAPIClient.shared.supertags(workspaceID: tanaWorkspaceID)
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    let available = Set(tanaSupertags.map(\.id))
    tanaSelectedSupertagIDs.formIntersection(available)
    saveTanaSettings()
  }

  private func saveTanaSettings() {
    let workspace = tanaWorkspaces.first(where: { $0.id == tanaWorkspaceID })
    if let workspace { tanaWorkspaceName = workspace.name }
    TanaSettingsStore.save(TanaSettings(
      enabled: tanaEnabled,
      workspaceID: tanaWorkspaceID.isEmpty ? nil : tanaWorkspaceID,
      workspaceName: tanaWorkspaceName.isEmpty ? nil : tanaWorkspaceName,
      selectedSupertagIDs: tanaSelectedSupertagIDs
    ))
  }

  var meetingDayTitle: String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(selectedMeetingDate) { return "Today" }
    if calendar.isDateInYesterday(selectedMeetingDate) { return "Yesterday" }
    return selectedMeetingDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }

  var canShowNextMeetingDay: Bool {
    !Calendar.autoupdatingCurrent.isDateInToday(selectedMeetingDate)
  }

  func showPreviousMeetingDay() {
    moveMeetingDay(by: -1)
  }

  func showNextMeetingDay() {
    guard canShowNextMeetingDay else { return }
    moveMeetingDay(by: 1)
  }

  private func moveMeetingDay(by days: Int) {
    let calendar = Calendar.autoupdatingCurrent
    guard let date = calendar.date(byAdding: .day, value: days, to: selectedMeetingDate) else {
      return
    }
    selectedMeetingDate = calendar.startOfDay(for: min(date, Date()))
    followsCurrentDay = calendar.isDateInToday(selectedMeetingDate)
    meetingPendingDeletion = nil
    meetingPendingRename = nil
    Task { await refreshMeetingDay() }
  }

  /// Rolls the list forward when the calendar day changes underneath an open
  /// app. Only a list that was already showing "today" moves; a deliberately
  /// selected earlier day is left alone.
  func handleDayChange() {
    guard followsCurrentDay else { return }
    let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    guard selectedMeetingDate != today else { return }
    selectedMeetingDate = today
    meetingPendingDeletion = nil
    meetingPendingRename = nil
    Task { await refreshMeetingDay() }
  }

  func refreshMeetingDay() async {
    let requestedDate = selectedMeetingDate
    let completed = await store.meetingsForDisplay(on: requestedDate).map {
      TodayMeetingSummary(
        id: $0.id,
        title: $0.title,
        startedAt: $0.startedAt,
        endedAt: $0.endedAt,
        summary: $0.insights?.summary,
        status: $0.status
      )
    }
    guard Calendar.autoupdatingCurrent.isDate(requestedDate, inSameDayAs: selectedMeetingDate)
    else { return }
    displayedMeetings = Self.mergeMeetingSummaries(
      completed: completed,
      pending: Array(pendingMeetingSummaries.values),
      on: requestedDate,
      calendar: .autoupdatingCurrent
    )
  }

  nonisolated static func mergeMeetingSummaries(
    completed: [TodayMeetingSummary],
    pending: [TodayMeetingSummary],
    on date: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> [TodayMeetingSummary] {
    let completedIDs = Set(completed.map(\.id))
    let visiblePending = pending.filter {
      !completedIDs.contains($0.id) && calendar.isDate($0.startedAt, inSameDayAs: date)
    }
    return (completed + visiblePending).sorted { $0.startedAt > $1.startedAt }
  }

  /// Shows the just-stopped meeting in today's list immediately, before
  /// transcription and enrichment finish, so stopping feels complete right away.
  private func showPendingMeetingInList(_ document: MeetingDocument) {
    let pending = TodayMeetingSummary(
      id: document.id,
      title: document.title,
      startedAt: document.startedAt,
      endedAt: document.endedAt ?? Date(),
      summary: nil,
      status: .processing
    )
    pendingMeetingSummaries[pending.id] = pending
    selectedMeetingDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    followsCurrentDay = true
    guard !displayedMeetings.contains(where: { $0.id == pending.id }) else { return }
    displayedMeetings.insert(pending, at: 0)
  }

  func isMeetingFinalizing(_ meeting: TodayMeetingSummary) -> Bool {
    pendingMeetingSummaries[meeting.id] != nil
  }

  func isMeetingRecoverable(_ meeting: TodayMeetingSummary) -> Bool {
    meeting.status != .complete && !isMeetingFinalizing(meeting)
  }

  /// Meetings the app is actively capturing or finalizing in the background.
  /// These are intentionally excluded from recovery detection so a live or
  /// still-finalizing meeting never surfaces a "Recover capture" prompt.
  private var activelyManagedMeetingIDs: Set<UUID> {
    Set(pendingMeetingSummaries.keys).union(activeRecordingMeetingID.map { [$0] } ?? [])
  }

  private func refreshRecoverableMeetingAvailability() async {
    recoverableMeetingAvailable =
      await store.latestRecoverableFolder(excluding: activelyManagedMeetingIDs) != nil
  }

  var archiveSubtitle: String {
    remoteSyncEnabled ? "Saved locally · remote sync on" : "Saved locally"
  }

  var canSaveArchiveSettings: Bool {
    archiveSettingsValidationError == nil && (state == .idle || isFailed)
  }

  var canManageMeetings: Bool { state == .idle || isFailed }

  var canTestPostMeetingHook: Bool {
    canSaveArchiveSettings
      && postMeetingHookLocation != .disabled
      && !postMeetingHookCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var httpHookValidationError: String? {
    RemoteSyncService.Configuration.httpHookURLError(httpHookURLDraft)
  }

  var canTestHTTPHook: Bool {
    !httpHookURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && httpHookValidationError == nil
  }

  var archiveSettingsValidationError: String? {
    let configuration = archiveConfiguration
    if let error = configuration.validationError { return error }
    let archive = URL(
      fileURLWithPath: (configuration.localPath as NSString).expandingTildeInPath,
      isDirectory: true
    ).standardizedFileURL.path
    let spool = root.standardizedFileURL.path
    if archive == spool || archive.hasPrefix(spool + "/") {
      return "Choose an archive outside the private recovery spool."
    }
    return nil
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private var archiveConfiguration: RemoteSyncService.Configuration {
    RemoteSyncService.Configuration(
      destination: remoteSyncEnabled ? .remote : .local,
      host: remoteHostDraft.trimmingCharacters(in: .whitespacesAndNewlines),
      path: remotePathDraft.trimmingCharacters(in: .whitespacesAndNewlines),
      localPath: localArchivePathDraft.trimmingCharacters(in: .whitespacesAndNewlines),
      enabled: true,
      includeAudio: keepAudioAfterProcessing,
      postMeetingHookLocation: postMeetingHookLocation,
      postMeetingHookCommand: postMeetingHookCommand,
      httpHookURL: httpHookURLDraft.trimmingCharacters(in: .whitespacesAndNewlines),
      httpHookHeaders: httpHookHeadersDraft,
      httpHookPayload: httpHookPayload
    )
  }

  private var archiveDisplayName: String {
    remoteSyncEnabled ? remoteHostDraft : "the local archive"
  }

  func scheduleArchiveSettingsSave() {
    archiveSettingsSaveTask?.cancel()
    let configuration = archiveConfiguration
    guard archiveSettingsValidationError == nil else {
      settingsStatusText = ""
      return
    }
    settingsStatusText = "Saving…"
    archiveSettingsSaveTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      ArchiveSettingsStore.saveStorage(configuration)
      let savedConfiguration = ArchiveSettingsStore.load()
      await remoteSync.update(configuration: savedConfiguration)
      await store.enqueueCompleteArchive()
      await remoteSync.flush()
      guard !Task.isCancelled else { return }
      if let error = await remoteSync.lastError {
        settingsStatusText = "Sync failed: \(error)"
      } else {
        settingsStatusText = "Saved · \(savedConfiguration.destinationDescription)"
      }
    }
  }

  func schedulePostMeetingHookSettingsSave() {
    hookSettingsSaveTask?.cancel()
    guard canSaveArchiveSettings else {
      hookSettingsStatusText = archiveSettingsValidationError ?? "Hook settings could not be saved."
      return
    }
    let location = postMeetingHookLocation
    let command = postMeetingHookCommand
    hookSettingsStatusText = "Saving…"
    hookSettingsSaveTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      ArchiveSettingsStore.saveHook(location: location, command: command)
      let savedConfiguration = ArchiveSettingsStore.load()
      await remoteSync.update(configuration: savedConfiguration)
      guard !Task.isCancelled else { return }
      hookSettingsStatusText = "Saved"
    }
  }

  func scheduleHTTPHookSettingsSave() {
    httpHookSaveTask?.cancel()
    if let error = httpHookValidationError {
      httpHookStatusText = error
      return
    }
    let url = httpHookURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let headers = httpHookHeadersDraft
    let payload = httpHookPayload
    httpHookStatusText = "Saving…"
    httpHookSaveTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      ArchiveSettingsStore.saveHTTPHook(url: url, headers: headers, payload: payload)
      let savedConfiguration = ArchiveSettingsStore.load()
      await remoteSync.update(configuration: savedConfiguration)
      guard !Task.isCancelled else { return }
      httpHookStatusText = url.isEmpty ? "" : "Saved"
    }
  }

  func testHTTPHook() {
    guard canTestHTTPHook else { return }
    let configuration = archiveConfiguration
    httpHookStatusText = "Sending test request…"
    Task {
      do {
        try await remoteSync.testPostMeetingHTTPHook(configuration: configuration)
        httpHookStatusText = "Request accepted"
      } catch {
        httpHookStatusText = "Request failed: \(error.localizedDescription)"
      }
    }
  }

  func testPostMeetingHook() {
    guard canTestPostMeetingHook else { return }
    let configuration = archiveConfiguration
    hookSettingsStatusText = "Testing hook…"
    Task {
      do {
        try await remoteSync.testPostMeetingHook(configuration: configuration)
        hookSettingsStatusText = "Hook succeeded"
      } catch {
        let detail = error.localizedDescription
        if detail.contains("No such file or directory") || detail.contains("command not found") {
          hookSettingsStatusText =
            "Hook failed: \(detail) Required tools are not available to the non-interactive shell; add their folder to PATH in the command or use a wrapper script."
        } else {
          hookSettingsStatusText = "Hook failed: \(detail)"
        }
      }
    }
  }

  func chooseLocalArchiveDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Choose meeting archive"
    panel.prompt = "Choose"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    let expanded = (localArchivePathDraft as NSString).expandingTildeInPath
    panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
    if panel.runModal() == .OK, let url = panel.url {
      localArchivePathDraft = url.path
      settingsStatusText = ""
    }
  }

  func discussCurrentMeetingInCodex() {
    guard state == .recording || state == .paused, !codexLaunchingCurrentMeeting else { return }
    codexLaunchingCurrentMeeting = true
    Task {
      defer { codexLaunchingCurrentMeeting = false }
      guard let document = await store.current(), let folder = await store.currentFolder() else {
        reportError("Could not find the current meeting folder.")
        return
      }
      await openMeetingInCodex(document: document, folder: folder)
    }
  }

  func discussMeetingInCodex(_ meeting: TodayMeetingSummary) {
    guard state == .idle, codexLaunchingMeetingID == nil else { return }
    codexLaunchingMeetingID = meeting.id
    Task {
      defer { codexLaunchingMeetingID = nil }
      do {
        let (document, folder) = try await store.completedMeeting(id: meeting.id)
        await openMeetingInCodex(document: document, folder: folder)
      } catch {
        reportError("Could not open the meeting in Codex: \(error.localizedDescription)")
      }
    }
  }

  /// Builds the Codex context for a meeting folder inside the private spool,
  /// mapped onto the user-visible archive location.
  private func codexContext(document: MeetingDocument, folder: URL) -> CodexMeetingContext? {
    let projectPath = (archiveConfiguration.localPath as NSString).expandingTildeInPath
    let projectFolder = URL(fileURLWithPath: projectPath, isDirectory: true)
    let spoolRoot = root.standardizedFileURL.path + "/"
    let spoolFolder = folder.standardizedFileURL.path
    guard spoolFolder.hasPrefix(spoolRoot) else { return nil }
    let relativeMeetingPath = String(spoolFolder.dropFirst(spoolRoot.count))
    let archivedMeetingFolder = projectFolder.appending(
      path: relativeMeetingPath, directoryHint: .isDirectory)
    return CodexMeetingContext(
      meetingID: document.id,
      title: document.title,
      startedAt: document.startedAt,
      projectFolder: projectFolder,
      meetingFolder: archivedMeetingFolder)
  }

  private func openMeetingInCodex(document: MeetingDocument, folder: URL) async {
    if let threadID = document.codexThreadID, !threadID.isEmpty,
      let url = CodexThreadService.threadURL(threadID)
    {
      NSWorkspace.shared.open(url)
      showTransientStatus("Opened the existing Codex task")
      return
    }

    guard let context = codexContext(document: document, folder: folder) else {
      reportError("Could not locate the meeting inside the local archive.")
      return
    }
    await remoteSync.flush()
    statusText = "Creating Codex task…"
    do {
      let threadID = try await CodexThreadService.createThread(
        for: context,
        promptTemplate: CodexPromptSettingsStore.load())
      try await store.setCodexThreadID(threadID, for: document.id)
      guard let url = CodexThreadService.threadURL(threadID) else {
        throw CodexThreadService.ServiceError.protocolError("The task link was invalid.")
      }
      NSWorkspace.shared.open(url)
      showTransientStatus("Codex task created for this meeting")
      await remoteSync.flush()
      showCodexProjectHintIfNeeded(projectFolder: context.projectFolder)
    } catch {
      reportError("Could not create the Codex task: \(error.localizedDescription)")
    }
  }

  /// Silently creates a Codex task for a just-started meeting when the
  /// auto-create option is on. Never steals focus and never surfaces errors
  /// beyond a quiet status line: recording is the primary job here.
  private func autoCreateCodexThreadIfEnabled(document: MeetingDocument, folder: URL) {
    guard codexAutoCreateThreads else { return }
    guard document.codexThreadID == nil else { return }
    guard let context = codexContext(document: document, folder: folder) else { return }
    Task { [store] in
      do {
        let threadID = try await CodexThreadService.createThread(
          for: context,
          promptTemplate: CodexPromptSettingsStore.load())
        try await store.setCodexThreadID(threadID, for: document.id)
      } catch {
        // Auto-creation is best-effort; the Discuss button remains available.
      }
    }
  }

  /// Notifies the meeting's Codex task that the structured summary is ready.
  /// Runs only when the task already exists; posts without triggering a reply.
  private func notifyCodexSummaryReady(meetingID: UUID) async {
    guard codexSummaryMessageEnabled else { return }
    let template = CodexPromptSettingsStore.loadSummaryMessage()
    guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do {
      let (document, folder) = try await store.completedMeeting(id: meetingID)
      guard let threadID = document.codexThreadID, !threadID.isEmpty else { return }
      guard let context = codexContext(document: document, folder: folder) else { return }
      let message = CodexThreadService.renderTemplate(
        template,
        context: context)
      try await CodexThreadService.sendMessage(message, toThread: threadID)
    } catch {
      // Best-effort: the summary itself is already saved and synced.
    }
  }

  private static let codexProjectHintShownKey = "codexProjectHintShown"

  private func showCodexProjectHintIfNeeded(projectFolder: URL) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.codexProjectHintShownKey) else { return }
    defaults.set(true, forKey: Self.codexProjectHintShownKey)

    let alert = NSAlert()
    alert.messageText = "See all meeting tasks in Codex"
    alert.informativeText = """
      Meeting tasks open in Codex right away, but they are only grouped in the \
      sidebar once the meeting archive folder is added as a project.

      In Codex, open this folder once as a project:
      \(projectFolder.path)

      Make sure Codex is in Codex mode, not Work mode — in Work mode folders \
      do not appear as projects.
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Reveal Folder")
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.activateFileViewerSelecting([projectFolder])
    }
  }

  func setKeepAudioAfterProcessing(_ keepAudio: Bool) {
    guard keepAudioAfterProcessing != keepAudio else { return }
    keepAudioAfterProcessing = keepAudio
    AudioRetentionSettingsStore.save(keepAudio)
    showTransientStatus(keepAudio
      ? "Audio retention and archive sync enabled"
      : "Future audio will be deleted after processing")
    let configuration = archiveConfiguration
    Task {
      await remoteSync.update(configuration: configuration)
      await store.enqueueCompleteArchive()
      await remoteSync.flush()
      if let error = await remoteSync.lastError {
        reportWarning("Audio setting saved; archive update pending: \(error)")
      }
    }
  }

  func setAutomaticTranscriptDeletionEnabled(_ enabled: Bool) {
    guard automaticTranscriptDeletionEnabled != enabled else { return }
    automaticTranscriptDeletionEnabled = enabled
    saveTranscriptRetentionSettings()
    transcriptRetentionStatusText = enabled
      ? "Detailed records will be deleted after \(transcriptRetentionDays) days."
      : "Automatic deletion is off."
    if enabled {
      Task { await runTranscriptRetentionCleanup(reportStatus: true) }
    }
  }

  func setTranscriptRetentionDays(_ days: Int) {
    let validated = TranscriptRetentionSettings.validatedDays(days)
    guard transcriptRetentionDays != validated else { return }
    transcriptRetentionDays = validated
    saveTranscriptRetentionSettings()
    transcriptRetentionStatusText = "Detailed records will be deleted after \(validated) days."
    if automaticTranscriptDeletionEnabled {
      Task { await runTranscriptRetentionCleanup(reportStatus: true) }
    }
  }

  private func saveTranscriptRetentionSettings() {
    TranscriptRetentionSettingsStore.save(
      TranscriptRetentionSettings(
        enabled: automaticTranscriptDeletionEnabled,
        days: transcriptRetentionDays))
  }

  private func runTranscriptRetentionCleanup(reportStatus: Bool) async {
    guard automaticTranscriptDeletionEnabled else { return }
    let now = Date()
    guard let cutoff = Calendar.current.date(
      byAdding: .day, value: -transcriptRetentionDays, to: now)
    else { return }
    do {
      let count = try await store.purgeExpiredTranscripts(before: cutoff, now: now)
      guard count > 0 else { return }
      await remoteSync.flush()
      if reportStatus {
        if let error = await remoteSync.lastError {
          transcriptRetentionStatusText =
            "Deleted locally; archive cleanup is pending: \(error)"
        } else {
          transcriptRetentionStatusText =
            "Deleted detailed records from \(count) expired meeting\(count == 1 ? "" : "s")."
        }
      }
    } catch {
      if reportStatus {
        transcriptRetentionStatusText = "Cleanup failed: \(error.localizedDescription)"
      }
    }
  }

  private func startRetentionMaintenance() {
    retentionMaintenanceTask?.cancel()
    retentionMaintenanceTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(86_400))
        guard !Task.isCancelled, let self else { return }
        await self.runTranscriptRetentionCleanup(reportStatus: false)
      }
    }
  }

  private func startDeferredNotesMaintenance() {
    deferredNotesMaintenanceTask?.cancel()
    deferredNotesMaintenanceTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(900))
        guard !Task.isCancelled, let self else { return }
        await self.runDeferredNotesMaintenance(reportStatus: false)
      }
    }
  }

  private func runDeferredNotesMaintenance(reportStatus: Bool) async {
    guard state == .idle else { return }
    let folders = await store.completedMeetingFoldersAwaitingInsights(before: Date())
    guard !folders.isEmpty else {
      enrichmentRetryAvailable = false
      return
    }
    guard await ChatGPTAuthService.shared.isAuthenticated() else {
      enrichmentRetryAvailable = true
      return
    }

    state = .processing
    if reportStatus { statusText = "Creating delayed meeting notes…" }
    var lastError: Error?
    var enrichedMeetingIDs: [UUID] = []
    for folder in folders {
      do {
        let meeting = try await store.load(folder: folder)
        let insights = try await enricher.enrich(
          meeting, checkpointURL: folder.appending(path: "enrichment-checkpoint.json"))
        try await store.setInsights(insights)
        enrichedMeetingIDs.append(meeting.id)
      } catch {
        lastError = error
      }
    }
    await remoteSync.flush()
    for meetingID in enrichedMeetingIDs {
      await notifyCodexSummaryReady(meetingID: meetingID)
    }
    await refreshMeetingDay()
    state = .idle
    enrichmentRetryAvailable = lastError != nil
    if reportStatus {
      if let lastError {
        reportError("Some meeting notes could not be created: \(lastError.localizedDescription)")
      } else {
        showTransientStatus("Delayed meeting notes created and synced")
      }
    }
  }

  func refreshMicrophoneDevices() {
    microphoneDevices = MicrophoneSettingsStore.devices()
  }

  func setUseSystemDefaultMicrophone(_ enabled: Bool) {
    useSystemDefaultMicrophone = enabled
    MicrophoneSettingsStore.saveUseSystemDefault(enabled)
    refreshMicrophoneDevices()
  }

  func moveMicrophone(_ device: MicrophoneDeviceChoice, by offset: Int) {
    guard let current = microphoneDevices.firstIndex(where: { $0.id == device.id }) else { return }
    let includedIndices = microphoneDevices.indices.filter { !microphoneDevices[$0].isExcluded }
    guard let position = includedIndices.firstIndex(of: current) else { return }
    let destinationPosition = position + offset
    guard includedIndices.indices.contains(destinationPosition) else { return }
    microphoneDevices.swapAt(current, includedIndices[destinationPosition])
    MicrophoneSettingsStore.saveDevices(microphoneDevices)
  }

  func moveMicrophone(id: String, relativeTo targetID: String) {
    guard id != targetID,
      let source = microphoneDevices.firstIndex(where: { $0.id == id }),
      let target = microphoneDevices.firstIndex(where: { $0.id == targetID })
    else { return }
    let device = microphoneDevices.remove(at: source)
    microphoneDevices.insert(device, at: min(target, microphoneDevices.count))
    MicrophoneSettingsStore.saveDevices(microphoneDevices)
  }

  func setMicrophoneExcluded(_ device: MicrophoneDeviceChoice, excluded: Bool) {
    guard let index = microphoneDevices.firstIndex(where: { $0.id == device.id }) else { return }
    microphoneDevices[index].isExcluded = excluded
    MicrophoneSettingsStore.saveDevices(microphoneDevices)
  }

  func removeMicrophone(_ device: MicrophoneDeviceChoice) {
    guard !device.isConnected else { return }
    microphoneDevices.removeAll { $0.id == device.id }
    MicrophoneSettingsStore.saveDevices(microphoneDevices)
  }

  var canAddVocabularyEntry: Bool {
    let term = vocabularyTermDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    return term.count >= 3 && vocabularyEntries.count < VocabularySettingsStore.maximumEntries
  }

  func addVocabularyEntry() {
    let term = vocabularyTermDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard term.count >= 3 else {
      vocabularyStatusText = "Enter at least 3 characters."
      return
    }
    let aliases = vocabularyMishearingDraft.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }
    let newEntry = VocabularyEntry(term: term, aliases: Array(Set(aliases)).sorted())
    if let index = vocabularyEntries.firstIndex(where: {
      $0.term.caseInsensitiveCompare(term) == .orderedSame
    }) {
      vocabularyEntries[index] = newEntry
    } else {
      guard vocabularyEntries.count < VocabularySettingsStore.maximumEntries else {
        vocabularyStatusText = "The vocabulary can contain up to \(VocabularySettingsStore.maximumEntries) terms."
        return
      }
      vocabularyEntries.append(newEntry)
      vocabularyEntries.sort {
        $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
      }
    }
    persistVocabularyEntries(status: "Added \(term).")
    vocabularyTermDraft = ""
    vocabularyMishearingDraft = ""
  }

  func removeVocabularyEntry(_ entry: VocabularyEntry) {
    vocabularyEntries.removeAll { $0.id == entry.id }
    persistVocabularyEntries(status: "Removed \(entry.term).")
  }

  private func persistVocabularyEntries(status: String) {
    VocabularySettingsStore.save(vocabularyEntries)
    vocabularyStatusText = status
    Task { await transcriber.invalidateVocabulary() }
  }

  func requestMeetingDeletion(_ meeting: TodayMeetingSummary) {
    guard canManageMeetings else { return }
    meetingPendingRename = nil
    meetingPendingDeletion = meeting
  }

  func cancelMeetingDeletion() {
    meetingPendingDeletion = nil
  }

  func confirmMeetingDeletion() {
    guard canManageMeetings, let meeting = meetingPendingDeletion else { return }
    meetingPendingDeletion = nil
    Task { await deleteMeeting(meeting) }
  }

  private func deleteMeeting(_ meeting: TodayMeetingSummary) async {
    state = .processing
    statusText = "Deleting \(meeting.title)…"
    // A meeting that is still finalizing has a background task working in its
    // folder. Stop that first, so the transcription cannot recreate files
    // underneath the delete or resurrect the meeting afterwards.
    if let finalization = stoppedMeetingFinalizationTasks[meeting.id] {
      stoppedMeetingGracePeriods.remove(meeting.id)
      finalization.cancel()
      await finalization.value
      pendingMeetingSummaries[meeting.id] = nil
    }
    do {
      try await store.deleteMeeting(id: meeting.id)
      await refreshMeetingDay()
      state = .idle
      showTransientStatus("Deleted from Laptop and \(archiveDisplayName)")
    } catch {
      state = .idle
      reportError("Delete failed; local copy retained: \(error.localizedDescription)")
    }
  }

  func requestMeetingRename(_ meeting: TodayMeetingSummary) {
    guard state == .idle else { return }
    meetingPendingDeletion = nil
    meetingPendingRename = meeting
    meetingRenameDraft = meeting.title
  }

  func openMeetingSummary(_ meeting: TodayMeetingSummary) {
    openMeetingFile(meeting, named: "meeting.md")
  }

  func openMeetingTranscript(_ meeting: TodayMeetingSummary) {
    openMeetingFile(meeting, named: "transcript.md")
  }

  private func openMeetingFile(_ meeting: TodayMeetingSummary, named fileName: String) {
    Task {
      do {
        let (_, folder) = try await store.completedMeeting(id: meeting.id)
        let file = folder.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
          reportError("\(fileName) does not exist for this meeting.")
          return
        }
        NSWorkspace.shared.open(file)
      } catch {
        reportError("Could not open \(fileName): \(error.localizedDescription)")
      }
    }
  }

  func cancelMeetingRename() {
    meetingPendingRename = nil
    meetingRenameDraft = ""
  }

  var canConfirmMeetingRename: Bool {
    guard let meetingPendingRename else { return false }
    let clean = meetingRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    return state == .idle && !clean.isEmpty && clean != meetingPendingRename.title
  }

  func confirmMeetingRename() {
    guard state == .idle, let meeting = meetingPendingRename else { return }
    let clean = meetingRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != meeting.title else { return }
    meetingPendingRename = nil
    meetingRenameDraft = ""
    Task { await renameMeeting(meeting, to: clean) }
  }

  private func renameMeeting(_ meeting: TodayMeetingSummary, to newTitle: String) async {
    state = .processing
    statusText = "Renaming meeting…"
    do {
      try await store.renameCompletedMeeting(id: meeting.id, title: newTitle)
      await remoteSync.flush()
      await refreshMeetingDay()
      state = .idle
      if let syncError = await remoteSync.lastError {
        reportWarning("Renamed locally; archive update pending: \(syncError)")
      } else {
        showTransientStatus("Renamed in the archive")
      }
    } catch {
      state = .idle
      reportError("Rename failed: \(error.localizedDescription)")
    }
  }

  func recreateMeetingNotes(_ meeting: TodayMeetingSummary) {
    guard state == .idle else { return }
    meetingPendingDeletion = nil
    cancelMeetingRename()
    Task { await recreateMeetingNotesFile(meeting) }
  }

  private func recreateMeetingNotesFile(_ meeting: TodayMeetingSummary) async {
    state = .processing
    statusText = "Recreating summary…"
    do {
      let (document, folder) = try await store.completedMeeting(id: meeting.id)
      guard document.transcriptDeletedAt == nil, !document.transcript.isEmpty else {
        throw NSError(
          domain: "MeetingNotes", code: 13,
          userInfo: [
            NSLocalizedDescriptionKey:
              "The word-for-word transcript has been deleted, so these notes cannot be regenerated."
          ])
      }
      let insights = try await enricher.enrich(
        document, checkpointURL: folder.appending(path: "enrichment-checkpoint.json"))
      try await store.setCompletedMeetingInsights(
        insights, meetingID: document.id, in: folder)
      await remoteSync.flush()
      await notifyCodexSummaryReady(meetingID: document.id)
      await refreshMeetingDay()
      state = .idle
      if let syncError = await remoteSync.lastError {
        reportWarning("Summary recreated locally; archive update pending: \(syncError)")
      } else {
        showTransientStatus("Summary recreated and synced")
      }
    } catch {
      state = .idle
      reportError("Could not recreate the summary: \(error.localizedDescription)")
    }
  }

  func loadCalendarSuggestion() async {
    guard state == .idle, let suggestion = await calendar.currentMeeting() else { return }
    title = suggestion.title
    calendarMetadata = suggestion.metadata
  }

  func toggleRecording() {
    switch state {
    case .idle, .failed:
      recordingMeetingApp = detectedMeetingApp
      if detectedMeetingApp != nil {
        detectedMeetingApp = nil
        MeetingNotificationService.shared.suppressCurrentMeeting()
      }
      Task { await start() }
    case .recording, .paused: Task { await stop() }
    case .starting, .processing: break
    }
  }

  func togglePause() {
    switch state {
    case .recording: Task { await pause(userInitiated: true) }
    case .paused: Task { await resume() }
    default: break
    }
  }

  func updateTitle() {
    guard state == .recording || state == .paused else { return }
    let captureState = state == .paused ? "paused" : "recording"
    Task {
      try? await store.updateTitle(
        title.trimmingCharacters(in: .whitespacesAndNewlines), captureState: captureState)
    }
  }

  private func start() async {
    // A second meeting should never make the first recording wait out its
    // courtesy delay. Its audio is already safely stored, so finish it now.
    stoppedMeetingGracePeriods.removeAll()
    state = .starting
    statusText = "Requesting access…"
    do {
      guard await AVCaptureDevice.requestAccess(for: .audio) else {
        throw NSError(
          domain: "MeetingNotes", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Microphone access was denied"])
      }
      // Starting a recording is an explicit user action, so this is the one
      // place calendar access may prompt. Background refreshes never do.
      if await calendar.requestAccess(), calendarMetadata == nil,
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let suggestion = await calendar.currentMeeting()
      {
        title = suggestion.title
        calendarMetadata = suggestion.metadata
      }
      let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let startedDocument = try await store.begin(
        title: cleanTitle.isEmpty ? "Meeting" : cleanTitle, calendar: calendarMetadata)
      activeRecordingMeetingID = startedDocument.id
      if let startedFolder = await store.currentFolder() {
        autoCreateCodexThreadIfEnabled(document: startedDocument, folder: startedFolder)
      }
      guard let microphoneURL = await store.audioURL(named: "microphone.wav"),
        let systemURL = await store.audioURL(named: "system.wav")
      else { throw CocoaError(.fileNoSuchFile) }

      let liveSessionID = await live.start { [weak self, store] turn in
        try? await store.append(turn)
        await MainActor.run {
          self?.recentTurns.append(turn)
          if let count = self?.recentTurns.count, count > 4 {
            self?.recentTurns.removeFirst(count - 4)
          }
        }
      }
      // A single FIFO stream per capture keeps chunks in delivery order; one
      // unstructured Task per callback could reach the ASR actor out of order.
      let (liveFeed, liveFeedContinuation) = AsyncStream.makeStream(
        of: (samples: [Int16], source: TranscriptTurn.Source, wavPosition: Int).self,
        bufferingPolicy: .unbounded
      )
      liveFeedTask?.cancel()
      liveFeedTask = Task { [live] in
        for await chunk in liveFeed {
          await live.append(
            chunk.samples, source: chunk.source, sessionID: liveSessionID,
            wavPosition: chunk.wavPosition)
        }
      }
      microphone.onSamplesAtPosition = { samples, position in
        liveFeedContinuation.yield((samples, .microphone, position))
      }
      systemAudio.onSamplesAtPosition = { samples, position in
        liveFeedContinuation.yield((samples, .system, position))
      }
      self.liveFeedContinuation = liveFeedContinuation
      captureClock.start()
      microphone.usePreferredDevice(MicrophoneSettingsStore.preferredDeviceUID())
      try microphone.start(writingTo: microphoneURL, clock: captureClock)
      do { try await systemAudio.start(writingTo: systemURL, clock: captureClock) } catch {
        _ = try? microphone.stop()
        captureClock.reset()
        throw error
      }
      startedAt = Date()
      elapsed = 0
      startTimer()
      recordingWakeLock.acquire()
      state = .recording
      statusText = "Recording · Mac stays awake"
      updateMeetingAutoStop()
      Task { try? await transcriber.prepare() }
    } catch {
      _ = try? microphone.stop()
      _ = try? await systemAudio.stop()
      stopLiveFeed()
      await live.finish()
      captureClock.reset()
      recordingWakeLock.release()
      meetingAutoStopScheduler.cancel()
      recordingMeetingApp = nil
      activeRecordingMeetingID = nil
      state = .failed(error.localizedDescription)
      reportError(error.localizedDescription)
      try? await store.setStatus(.failed)
    }
  }

  private func pause(userInitiated: Bool) async {
    guard state == .recording else { return }
    recordingWakeLock.release()
    elapsed = captureClock.pause()
    timer?.invalidate()
    timer = nil
    microphone.pause()
    state = .starting
    statusText = "Pausing…"
    await systemAudio.pause()
    try? await store.heartbeat(captureState: "paused")
    state = .paused
    statusText = userInitiated ? "Paused" : "Paused while Mac sleeps"
  }

  private func resume() async {
    guard state == .paused else { return }
    state = .starting
    statusText = "Resuming…"
    do {
      captureClock.resume()
      do { try microphone.resume() } catch {
        _ = captureClock.pause()
        throw error
      }
      do { try await systemAudio.resume() } catch {
        _ = captureClock.pause()
        microphone.pause()
        throw error
      }
      startedAt = Date().addingTimeInterval(-elapsed)
      pausedBySleep = false
      startTimer()
      recordingWakeLock.acquire()
      state = .recording
      statusText = "Recording · Mac stays awake"
    } catch {
      state = .paused
      reportError("Resume failed: \(error.localizedDescription)")
    }
  }

  private func handleWillSleep() {
    guard state == .recording else { return }
    recordingWakeLock.release()
    pausedBySleep = true
    elapsed = captureClock.pause()
    timer?.invalidate()
    timer = nil
    microphone.pause()
    systemAudio.suspendImmediately()
    state = .paused
    statusText = "Paused while Mac sleeps"
    Task {
      await systemAudio.pause()
      try? await store.heartbeat(captureState: "paused")
    }
  }

  private func didWake() {
    // A Mac that slept across midnight may never receive the day-changed
    // notification, so the day is re-checked on every wake.
    handleDayChange()
    guard pausedBySleep, state == .paused else { return }
    statusText = "Paused after sleep — press Resume"
  }

  private func startTimer() {
    timer?.invalidate()
    lastHeartbeatElapsed = elapsed
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.elapsed = self.captureClock.elapsed
        if self.elapsed - self.lastHeartbeatElapsed >= 15 {
          self.lastHeartbeatElapsed = self.elapsed
          try? await self.store.heartbeat(captureState: "recording")
        }
      }
    }
  }

  private func stop() async {
    meetingAutoStopScheduler.cancel()
    recordingMeetingApp = nil
    recordingWakeLock.release()
    state = .processing
    statusText = "Saving recording…"
    timer?.invalidate()
    timer = nil
    pausedBySleep = false
    do {
      // Stop both recorders even when one of them throws, so a microphone
      // failure can never leak a live system-audio stream (or vice versa).
      let microphoneResult = Result { try microphone.stop() }
      let systemResult: Result<URL?, Error>
      do { systemResult = .success(try await systemAudio.stop()) } catch {
        systemResult = .failure(error)
      }
      guard let microphoneURL = try microphoneResult.get(),
        let systemURL = try systemResult.get()
      else { throw CocoaError(.fileNoSuchFile) }
      stopLiveFeed()
      await live.finish()
      let stoppedMeeting = try await store.prepareForFinalization()
      activeRecordingMeetingID = nil
      showPendingMeetingInList(stoppedMeeting.document)
      queueStoppedMeetingFinalization(
        stoppedMeeting,
        microphoneURL: microphoneURL,
        systemURL: systemURL
      )

      // The audio files and an explicit processing state are now durable. Let
      // the next meeting begin while this one is transcribed in the background.
      state = .idle
      captureClock.reset()
      startedAt = nil
      elapsed = 0
      recentTurns = []
      title = ""
      calendarMetadata = nil
      await loadCalendarSuggestion()
    } catch {
      try? await store.setStatus(.failed)
      state = .failed(error.localizedDescription)
      reportError(error.localizedDescription)
    }
  }

  private func queueStoppedMeetingFinalization(
    _ stoppedMeeting: MeetingStore.StoppedMeeting,
    microphoneURL: URL,
    systemURL: URL
  ) {
    let meetingID = stoppedMeeting.document.id
    stoppedMeetingGracePeriods.insert(meetingID)
    statusText = "Recording saved · finalizing in 30s"
    stoppedMeetingFinalizationTasks[meetingID] = Task { [weak self] in
      await self?.finalizeStoppedMeeting(
        stoppedMeeting,
        microphoneURL: microphoneURL,
        systemURL: systemURL
      )
    }
  }

  private func finalizeStoppedMeeting(
    _ stoppedMeeting: MeetingStore.StoppedMeeting,
    microphoneURL: URL,
    systemURL: URL
  ) async {
    let meetingID = stoppedMeeting.document.id
    defer {
      stoppedMeetingGracePeriods.remove(meetingID)
      stoppedMeetingFinalizationTasks[meetingID] = nil
    }

    for remaining in stride(from: 30, through: 1, by: -1) {
      guard stoppedMeetingGracePeriods.contains(meetingID) else { break }
      if state == .idle { statusText = "Recording saved · finalizing in \(remaining)s" }
      try? await Task.sleep(for: .seconds(1))
    }

    if state == .idle { statusText = "Finishing transcript…" }
    var enrichmentWarning: String?
    var insights: MeetingInsights?
    do {
      let turns = try await final.process(microphone: microphoneURL, system: systemURL)
      var document = stoppedMeeting.document
      document.transcript = turns
      document.status = .processing
      do {
        insights = try await enricher.enrich(
          document,
          checkpointURL: stoppedMeeting.folder.appending(path: "enrichment-checkpoint.json")
        )
      } catch {
        enrichmentWarning = error.localizedDescription
      }
      _ = try await store.finalizeStoppedMeeting(
        in: stoppedMeeting.folder,
        turns: turns,
        insights: insights
      )
    } catch {
      try? await store.markStoppedMeetingFailed(in: stoppedMeeting.folder)
      pendingMeetingSummaries[meetingID] = nil
      await refreshRecoverableMeetingAvailability()
      await refreshMeetingDay()
      guard state == .idle else { return }
      reportError("Finalization retained: \(error.localizedDescription)")
      return
    }
    if insights != nil { await notifyCodexSummaryReady(meetingID: meetingID) }

    // Once meeting.json and the Markdown artifacts are complete, housekeeping
    // failures must not downgrade the meeting back to failed.
    var cleanupWarning: String?
    if !keepAudioAfterProcessing {
      do {
        try await store.removeAudioFiles(in: stoppedMeeting.folder)
      } catch {
        cleanupWarning = error.localizedDescription
      }
    }
    await remoteSync.flush()
    pendingMeetingSummaries[meetingID] = nil
    await refreshRecoverableMeetingAvailability()
    enrichmentRetryAvailable = await store.latestNeedsEnrichmentFolder() != nil
    await refreshMeetingDay()
    guard state == .idle else { return }
    if let cleanupWarning {
      reportWarning("Meeting saved; audio cleanup pending: \(cleanupWarning)")
    } else if let syncError = await remoteSync.lastError {
      reportWarning("Saved locally; remote sync pending: \(syncError)")
    } else if let enrichmentWarning {
      reportWarning("Transcript saved; \(enrichmentWarning)")
    } else {
      showTransientStatus(remoteSyncEnabled
        ? "Saved locally and synced to \(archiveDisplayName)"
        : "Saved to the local archive")
    }
  }

  private func updateMeetingAutoStop() {
    let isCapturing = state == .recording || state == .paused
    let app = recordingMeetingApp
    meetingAutoStopScheduler.update(
      recordingMeetingApp: app,
      detectedMeetingApp: latestDetectedMeetingApp,
      isCapturing: isCapturing
    ) { [weak self] in
      guard let self, self.state == .recording || self.state == .paused else { return }
      self.statusText = "\(app ?? "Video meeting") ended · finishing…"
      await self.stop()
    }
  }

  func recoverLatestMeeting() {
    Task { await recover(meetingID: nil) }
  }

  func recoverMeeting(_ meeting: TodayMeetingSummary) {
    Task { await recover(meetingID: meeting.id) }
  }

  private func recover(meetingID: UUID?) async {
    let folder = if let meetingID {
      await store.recoverableFolder(id: meetingID, excluding: activelyManagedMeetingIDs)
    } else {
      await store.latestRecoverableFolder(excluding: activelyManagedMeetingIDs)
    }
    guard let folder else {
      recoverableMeetingAvailable = false
      if meetingID != nil {
        state = .idle
        reportError("No usable speech was captured for this meeting")
      }
      return
    }
    state = .processing
    statusText = "Recovering transcript…"
    var finalized = false
    do {
      let recoveredDocument = try await store.load(folder: folder)
      let microphoneURL = folder.appending(path: "microphone.wav")
      let systemURL = folder.appending(path: "system.wav")
      for url in [microphoneURL, systemURL]
      where FileManager.default.fileExists(atPath: url.path) {
        try WavFile.repairHeader(at: url)
      }
      let turns = try await final.process(microphone: microphoneURL, system: systemURL)
      try await store.setFinalTranscript(turns)
      let meeting = await store.current()
      var insights: MeetingInsights?
      var enrichmentWarning: String?
      if let meeting {
        let checkpoint = folder.appending(path: "enrichment-checkpoint.json")
        do { insights = try await enricher.enrich(meeting, checkpointURL: checkpoint) } catch {
          enrichmentWarning = error.localizedDescription
        }
      }
      try await store.finalize(insights: insights)
      finalized = true
      if insights != nil { await notifyCodexSummaryReady(meetingID: recoveredDocument.id) }
      var cleanupWarning: String?
      if !keepAudioAfterProcessing {
        do { try await store.removeAudioFiles() } catch {
          cleanupWarning = error.localizedDescription
        }
      }
      await remoteSync.flush()
      recentTurns = Array(turns.suffix(4))
      pendingMeetingSummaries[recoveredDocument.id] = nil
      await refreshRecoverableMeetingAvailability()
      enrichmentRetryAvailable = await store.latestNeedsEnrichmentFolder() != nil
      state = .idle
      selectedMeetingDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
      followsCurrentDay = true
      await refreshMeetingDay()
      if let cleanupWarning {
        reportWarning("Meeting recovered; audio cleanup pending: \(cleanupWarning)")
      } else if let enrichmentWarning {
        reportWarning("Transcript recovered; \(enrichmentWarning)")
      } else {
        showTransientStatus(remoteSyncEnabled
          ? "Recovered locally and synced to \(archiveDisplayName)"
          : "Recovered and saved locally")
      }
    } catch {
      if !finalized { try? await store.setStatus(.failed) }
      await refreshRecoverableMeetingAvailability()
      state = .failed(error.localizedDescription)
      reportError("Recovery retained: \(error.localizedDescription)")
    }
  }

  func retryEnrichment() {
    Task { await retryLatestEnrichment() }
  }

  private func retryLatestEnrichment() async {
    guard let folder = await store.latestNeedsEnrichmentFolder() else {
      enrichmentRetryAvailable = false
      return
    }
    state = .processing
    statusText = "Retrying structured notes…"
    do {
      let meeting = try await store.load(folder: folder)
      let insights = try await enricher.enrich(
        meeting,
        checkpointURL: folder.appending(path: "enrichment-checkpoint.json")
      )
      try await store.setInsights(insights)
      await remoteSync.flush()
      await notifyCodexSummaryReady(meetingID: meeting.id)
      enrichmentRetryAvailable = false
      state = .idle
      await refreshMeetingDay()
      if await remoteSync.lastError == nil {
        showTransientStatus(remoteSyncEnabled
          ? "Structured notes saved locally and synced to \(archiveDisplayName)"
          : "Structured notes saved to the local archive")
      } else {
        reportWarning("Structured notes saved; remote sync pending")
      }
    } catch {
      state = .idle
      enrichmentRetryAvailable = true
      reportError("Structured notes retry failed: \(error.localizedDescription)")
    }
  }

  /// Detaches the recorders from the live-transcription feed and ends the
  /// FIFO stream so the consumer task can finish.
  private func stopLiveFeed() {
    microphone.onSamplesAtPosition = nil
    systemAudio.onSamplesAtPosition = nil
    liveFeedContinuation?.finish()
    liveFeedContinuation = nil
    liveFeedTask = nil
  }

  private func showTransientStatus(_ message: String) {
    transientStatusTask?.cancel()
    statusText = message
    transientStatusTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, let self, self.state == .idle, self.statusText == message else {
        return
      }
      self.statusText = "Ready"
      self.transientStatusTask = nil
    }
  }

  /// Reports a user-visible failure through the status line.
  private func reportError(_ message: String) {
    statusText = message
    statusSeverity = .error
  }

  /// Reports a partially successful outcome (saved locally, follow-up pending).
  private func reportWarning(_ message: String) {
    statusText = message
    statusSeverity = .warning
  }

}
