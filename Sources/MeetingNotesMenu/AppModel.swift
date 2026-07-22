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

  var state: State = .idle
  var title = "Meeting"
  var elapsed: TimeInterval = 0
  var recentTurns: [TranscriptTurn] = []
  var statusText = "Ready"
  var chatGPTAuthenticated = false
  var chatGPTAuthInProgress = false
  var chatGPTAuthStatusText = "Checking sign-in…"
  var recoverableMeetingAvailable = false
  var enrichmentRetryAvailable = false
  var displayedMeetings: [TodayMeetingSummary] = []
  var selectedMeetingDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
  var meetingPendingDeletion: TodayMeetingSummary?
  var meetingPendingRename: TodayMeetingSummary?
  var meetingRenameDraft = ""
  var remoteSyncEnabled = false
  var remoteHostDraft = RemoteSyncService.Configuration.defaults.host
  var remotePathDraft = RemoteSyncService.Configuration.defaults.path
  var localArchivePathDraft = RemoteSyncService.Configuration.defaults.localPath
  var postMeetingHookLocation = RemoteSyncService.Configuration.defaults.postMeetingHookLocation
  var postMeetingHookCommand = RemoteSyncService.Configuration.defaults.postMeetingHookCommand
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

  var tanaSupertagChoices: [TanaSupertagChoice] {
    TanaSupertagChoice.grouped(tanaSupertags)
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
  private var pausedBySleep = false
  private var workspaceObservers: [NSObjectProtocol] = []
  private var calendarMetadata: CalendarMetadata?
  private var retentionMaintenanceTask: Task<Void, Never>?
  private var deferredNotesMaintenanceTask: Task<Void, Never>?
  private var transientStatusTask: Task<Void, Never>?
  private var archiveSettingsSaveTask: Task<Void, Never>?
  private var hookSettingsSaveTask: Task<Void, Never>?
  private var latestDetectedMeetingApp: String?
  private var recordingMeetingApp: String?

  init() {
    let archiveConfiguration = ArchiveSettingsStore.load()
    root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "MeetingNotesMenu/Spool", directoryHint: .isDirectory)
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
    let transcriptRetention = TranscriptRetentionSettingsStore.load()
    automaticTranscriptDeletionEnabled = transcriptRetention.enabled
    transcriptRetentionDays = transcriptRetention.days
    let tanaSettings = TanaSettingsStore.load()
    tanaEnabled = tanaSettings.enabled
    tanaWorkspaceID = tanaSettings.workspaceID ?? ""
    tanaWorkspaceName = tanaSettings.workspaceName ?? ""
    tanaSelectedSupertagIDs = tanaSettings.selectedSupertagIDs
    microphone.onSamples = { [live] samples in
      Task { await live.append(samples, source: .microphone) }
    }
    systemAudio.onSamples = { [live] samples in Task { await live.append(samples, source: .system) }
    }
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

  func dismissDetectedMeeting() {
    detectedMeetingApp = nil
    MeetingNotificationService.shared.suppressCurrentMeeting()
    if state == .idle { statusText = "Ready" }
  }

  func recordDetectedMeeting() {
    guard state == .idle else { return }
    let app = detectedMeetingApp
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == "Meeting",
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
    recoverableMeetingAvailable = await store.latestRecoverableFolder() != nil
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
        domain: "MeetingNotesMenu", code: 8,
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
        domain: "MeetingNotesMenu", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Transcript repaired locally; sync failed: \(syncError)"])
    }
  }

  func regenerateMeetingInsights(at targetFolder: URL) async throws {
    let spool = root.standardizedFileURL.path
    let target = targetFolder.standardizedFileURL
    guard target.path.hasPrefix(spool + "/") else {
      throw NSError(
        domain: "MeetingNotesMenu", code: 10,
        userInfo: [NSLocalizedDescriptionKey: "The insights target is outside the private spool"])
    }
    let meeting = try await store.load(folder: target)
    guard meeting.status == .complete, !meeting.transcript.isEmpty else {
      throw NSError(
        domain: "MeetingNotesMenu", code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Only a completed meeting with a transcript can be enriched"])
    }
    let insights = try await enricher.enrich(
      meeting, checkpointURL: target.appending(path: "enrichment-checkpoint.json"))
    try await store.setInsights(insights)
    await remoteSync.flush()
    if let syncError = await remoteSync.lastError {
      throw NSError(
        domain: "MeetingNotesMenu", code: 12,
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
    meetingPendingDeletion = nil
    meetingPendingRename = nil
    Task { await refreshMeetingDay() }
  }

  func refreshMeetingDay() async {
    let requestedDate = selectedMeetingDate
    let meetings = await store.completedMeetings(on: requestedDate).map {
      TodayMeetingSummary(
        id: $0.id,
        title: $0.title,
        startedAt: $0.startedAt,
        endedAt: $0.endedAt,
        summary: $0.insights?.summary
      )
    }
    guard Calendar.autoupdatingCurrent.isDate(requestedDate, inSameDayAs: selectedMeetingDate)
    else { return }
    displayedMeetings = meetings
  }

  var archiveSubtitle: String {
    remoteSyncEnabled ? "Saved locally · remote sync on" : "Saved locally"
  }

  var canSaveArchiveSettings: Bool {
    archiveSettingsValidationError == nil && (state == .idle || isFailed)
  }

  var canTestPostMeetingHook: Bool {
    canSaveArchiveSettings
      && postMeetingHookLocation != .disabled
      && !postMeetingHookCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
      postMeetingHookCommand: postMeetingHookCommand
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
        statusText = "Could not find the current meeting folder."
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
        let (document, folder) = try await store.loadCompletedMeeting(id: meeting.id)
        await openMeetingInCodex(document: document, folder: folder)
      } catch {
        statusText = "Could not open the meeting in Codex: \(error.localizedDescription)"
      }
    }
  }

  private func openMeetingInCodex(document: MeetingDocument, folder: URL) async {
    if let threadID = document.codexThreadID, !threadID.isEmpty,
      let url = CodexThreadService.threadURL(threadID)
    {
      NSWorkspace.shared.open(url)
      showTransientStatus("Opened the existing Codex task")
      return
    }

    let projectPath = (archiveConfiguration.localPath as NSString).expandingTildeInPath
    let projectFolder = URL(
      fileURLWithPath: projectPath,
      isDirectory: true)
    let spoolRoot = root.standardizedFileURL.path + "/"
    let spoolFolder = folder.standardizedFileURL.path
    guard spoolFolder.hasPrefix(spoolRoot) else {
      statusText = "Could not locate the meeting inside the local archive."
      return
    }
    let relativeMeetingPath = String(spoolFolder.dropFirst(spoolRoot.count))
    await remoteSync.flush()
    let archivedMeetingFolder = projectFolder.appending(
      path: relativeMeetingPath, directoryHint: .isDirectory)
    let context = CodexMeetingContext(
      meetingID: document.id,
      title: document.title,
      startedAt: document.startedAt,
      projectFolder: projectFolder,
      meetingFolder: archivedMeetingFolder)
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
    } catch {
      statusText = "Could not create the Codex task: \(error.localizedDescription)"
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
        statusText = "Audio setting saved; archive update pending: \(error)"
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
    for folder in folders {
      do {
        let meeting = try await store.load(folder: folder)
        let insights = try await enricher.enrich(
          meeting, checkpointURL: folder.appending(path: "enrichment-checkpoint.json"))
        try await store.setInsights(insights)
      } catch {
        lastError = error
      }
    }
    await remoteSync.flush()
    await refreshMeetingDay()
    state = .idle
    enrichmentRetryAvailable = lastError != nil
    if reportStatus {
      if let lastError {
        statusText = "Some meeting notes could not be created: \(lastError.localizedDescription)"
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
    guard state == .idle else { return }
    meetingPendingRename = nil
    meetingPendingDeletion = meeting
  }

  func cancelMeetingDeletion() {
    meetingPendingDeletion = nil
  }

  func confirmMeetingDeletion() {
    guard state == .idle, let meeting = meetingPendingDeletion else { return }
    meetingPendingDeletion = nil
    Task { await deleteMeeting(meeting) }
  }

  private func deleteMeeting(_ meeting: TodayMeetingSummary) async {
    state = .processing
    statusText = "Deleting \(meeting.title)…"
    do {
      try await store.deleteCompletedMeeting(id: meeting.id)
      await refreshMeetingDay()
      state = .idle
      showTransientStatus("Deleted from Laptop and \(archiveDisplayName)")
    } catch {
      state = .idle
      statusText = "Delete failed; local copy retained: \(error.localizedDescription)"
    }
  }

  func requestMeetingRename(_ meeting: TodayMeetingSummary) {
    guard state == .idle else { return }
    meetingPendingDeletion = nil
    meetingPendingRename = meeting
    meetingRenameDraft = meeting.title
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
        statusText = "Renamed locally; archive update pending: \(syncError)"
      } else {
        showTransientStatus("Renamed in the archive")
      }
    } catch {
      state = .idle
      statusText = "Rename failed: \(error.localizedDescription)"
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
    statusText = "Recreating meeting notes…"
    do {
      let (document, folder) = try await store.loadCompletedMeeting(id: meeting.id)
      guard document.transcriptDeletedAt == nil, !document.transcript.isEmpty else {
        throw NSError(
          domain: "MeetingNotesMenu", code: 13,
          userInfo: [
            NSLocalizedDescriptionKey:
              "The word-for-word transcript has been deleted, so these notes cannot be regenerated."
          ])
      }
      let insights = try await enricher.enrich(
        document, checkpointURL: folder.appending(path: "enrichment-checkpoint.json"))
      try await store.setInsights(insights)
      await remoteSync.flush()
      await refreshMeetingDay()
      state = .idle
      if let syncError = await remoteSync.lastError {
        statusText = "Meeting notes recreated locally; archive update pending: \(syncError)"
      } else {
        showTransientStatus("Meeting notes recreated and synced")
      }
    } catch {
      state = .idle
      statusText = "Could not recreate meeting notes: \(error.localizedDescription)"
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
    state = .starting
    statusText = "Requesting access…"
    do {
      guard await AVCaptureDevice.requestAccess(for: .audio) else {
        throw NSError(
          domain: "MeetingNotesMenu", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Microphone access was denied"])
      }
      let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try await store.begin(
        title: cleanTitle.isEmpty ? "Meeting" : cleanTitle, calendar: calendarMetadata)
      guard let microphoneURL = await store.audioURL(named: "microphone.wav"),
        let systemURL = await store.audioURL(named: "system.wav")
      else { throw CocoaError(.fileNoSuchFile) }

      await live.start { [weak self, store] turn in
        try? await store.append(turn)
        await MainActor.run {
          self?.recentTurns.append(turn)
          if let count = self?.recentTurns.count, count > 4 {
            self?.recentTurns.removeFirst(count - 4)
          }
        }
      }
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
      await live.finish()
      captureClock.reset()
      recordingWakeLock.release()
      meetingAutoStopScheduler.cancel()
      recordingMeetingApp = nil
      state = .failed(error.localizedDescription)
      statusText = error.localizedDescription
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
      try microphone.resume()
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
      statusText = "Resume failed: \(error.localizedDescription)"
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
    guard pausedBySleep, state == .paused else { return }
    statusText = "Paused after sleep — press Resume"
  }

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.elapsed = self.captureClock.elapsed
        if Int(self.elapsed).isMultiple(of: 15) {
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
    statusText = "Finishing transcript…"
    timer?.invalidate()
    timer = nil
    pausedBySleep = false
    do {
      guard let microphoneURL = try microphone.stop(),
        let systemURL = try await systemAudio.stop()
      else { throw CocoaError(.fileNoSuchFile) }
      await live.finish()
      try await store.setStatus(.processing)
      let turns = try await final.process(microphone: microphoneURL, system: systemURL)
      try await store.setFinalTranscript(turns)
      let meeting = await store.current()
      var enrichmentWarning: String?
      var insights: MeetingInsights?
      if let meeting {
        let checkpoint = (await store.currentFolder())?.appending(
          path: "enrichment-checkpoint.json")
        do { insights = try await enricher.enrich(meeting, checkpointURL: checkpoint) } catch {
          enrichmentWarning = error.localizedDescription
        }
      }
      try await store.finalize(insights: insights)
      if !keepAudioAfterProcessing { try await store.removeAudioFiles() }
      await remoteSync.flush()
      recentTurns = Array(turns.suffix(4))
      if let syncError = await remoteSync.lastError {
        statusText = "Saved locally; remote sync pending: \(syncError)"
      } else if let enrichmentWarning {
        statusText = "Transcript saved; \(enrichmentWarning)"
      } else {
        showTransientStatus(remoteSyncEnabled
          ? "Saved locally and synced to \(archiveDisplayName)"
          : "Saved to the local archive")
      }
      state = .idle
      captureClock.reset()
      startedAt = nil
      enrichmentRetryAvailable = insights == nil
      selectedMeetingDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
      await refreshMeetingDay()
      await loadCalendarSuggestion()
    } catch {
      try? await store.setStatus(.failed)
      state = .failed(error.localizedDescription)
      statusText = error.localizedDescription
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
    Task { await recover() }
  }

  private func recover() async {
    guard let folder = await store.latestRecoverableFolder() else {
      recoverableMeetingAvailable = false
      return
    }
    state = .processing
    statusText = "Recovering transcript…"
    do {
      _ = try await store.load(folder: folder)
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
      if !keepAudioAfterProcessing { try await store.removeAudioFiles() }
      await remoteSync.flush()
      recentTurns = Array(turns.suffix(4))
      recoverableMeetingAvailable = false
      enrichmentRetryAvailable = insights == nil
      state = .idle
      selectedMeetingDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
      await refreshMeetingDay()
      if let enrichmentWarning {
        statusText = "Transcript recovered; \(enrichmentWarning)"
      } else {
        showTransientStatus(remoteSyncEnabled
          ? "Recovered locally and synced to \(archiveDisplayName)"
          : "Recovered and saved locally")
      }
    } catch {
      try? await store.setStatus(.failed)
      state = .failed(error.localizedDescription)
      statusText = "Recovery retained: \(error.localizedDescription)"
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
      enrichmentRetryAvailable = false
      state = .idle
      await refreshMeetingDay()
      if await remoteSync.lastError == nil {
        showTransientStatus(remoteSyncEnabled
          ? "Structured notes saved locally and synced to \(archiveDisplayName)"
          : "Structured notes saved to the local archive")
      } else {
        statusText = "Structured notes saved; remote sync pending"
      }
    } catch {
      state = .idle
      enrichmentRetryAvailable = true
      statusText = "Structured notes retry failed: \(error.localizedDescription)"
    }
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

}
