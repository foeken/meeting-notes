import Foundation

/// How much disk the meeting storage uses, split the way users think about
/// it: documents worth keeping, and audio that can be cleaned up.
struct MeetingStorageUsage: Equatable, Sendable {
  var documentBytes: Int64 = 0
  var archiveAudioBytes: Int64 = 0
  var recoveryAudioBytes: Int64 = 0
  var audioBytes: Int64 { archiveAudioBytes + recoveryAudioBytes }
  var totalBytes: Int64 { documentBytes + audioBytes }
}

actor MeetingStore {
  struct StoppedMeeting: Sendable {
    let document: MeetingDocument
    let folder: URL
  }

  /// The private spool: live captures and interrupted captures awaiting
  /// recovery. A finished meeting moves out of here permanently.
  private let root: URL
  /// The user-facing archive: finished meetings, exactly one copy.
  private var archiveRoot: URL
  private let sync: RemoteSyncService
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var meeting: MeetingDocument?
  private var folder: URL?

  /// `archiveRoot` defaults to `root`, which disables promotion entirely: a
  /// store whose two roots coincide treats every folder as already archived.
  /// The app always passes a distinct archive root.
  init(root: URL, archiveRoot: URL? = nil, sync: RemoteSyncService) {
    self.root = root
    self.archiveRoot = archiveRoot ?? root
    self.sync = sync
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  func updateArchiveRoot(_ url: URL) {
    archiveRoot = url
  }

  static let stateFileName = "meeting.json"
  /// The archive keeps its state file hidden so a browsing user sees only the
  /// Markdown documents.
  static let hiddenStateFileName = ".meeting.json"
  /// Meeting folders are `year/month/day/meeting`, four components deep.
  static let meetingPathComponentCount = 4

  private static func isStateFile(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name == stateFileName || name == hiddenStateFileName
  }

  /// The state file inside `folder`, preferring the hidden archive name.
  private func stateURL(in folder: URL) -> URL {
    let hidden = folder.appending(path: Self.hiddenStateFileName)
    if FileManager.default.fileExists(atPath: hidden.path) { return hidden }
    return folder.appending(path: Self.stateFileName)
  }

  private func isArchiveFolder(_ folder: URL) -> Bool {
    folder.standardizedFileURL.path.hasPrefix(archiveRoot.standardizedFileURL.path + "/")
  }

  private func baseRoot(of folder: URL) -> URL {
    isArchiveFolder(folder) ? archiveRoot : root
  }

  /// Every meeting state file across both roots: the spool for live and
  /// recoverable captures, the archive for finished meetings.
  private func allStateURLs(keys: [URLResourceKey]? = nil) -> [URL] {
    let manager = FileManager.default
    var seenRoots = Set<String>()
    var results: [URL] = []
    for base in [root, archiveRoot] {
      guard seenRoots.insert(base.standardizedFileURL.path).inserted else { continue }
      guard let enumerator = manager.enumerator(at: base, includingPropertiesForKeys: keys)
      else { continue }
      for case let url as URL in enumerator where Self.isStateFile(url) {
        results.append(url)
      }
    }
    return results
  }

  func begin(title: String, calendar: CalendarMetadata?) throws -> MeetingDocument {
    let now = Date()
    let document = MeetingDocument(
      id: UUID(), title: title, startedAt: now, calendar: calendar,
      status: .recording, transcript: []
    )
    let relativeFolder =
      DateFormatter.folderDay.string(from: now) + "/"
      + "\(DateFormatter.fileTime.string(from: now))-\(title.filenameSafe.isEmpty ? "meeting" : title.filenameSafe)-\(document.id.uuidString.prefix(8))"
    let folder = root.appending(path: relativeFolder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    self.folder = folder
    meeting = document
    try persist()
    try persistPointer(active: true, captureState: "recording")
    return document
  }

  func load(folder: URL) throws -> MeetingDocument {
    let data = try Data(contentsOf: stateURL(in: folder))
    let document = try decoder.decode(MeetingDocument.self, from: data)
    self.folder = folder
    meeting = document
    return document
  }

  /// Finds a completed meeting without changing the active capture held by the store.
  func completedMeeting(id: UUID) throws -> (document: MeetingDocument, folder: URL) {
    let target = allStateURLs()
      .compactMap { url -> (MeetingDocument, URL)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.id == id,
          document.status == .complete
        else { return nil }
        return (document, url.deletingLastPathComponent())
      }
      .first
    guard let (document, targetFolder) = target else {
      throw NSError(
        domain: "MeetingStore", code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Completed meeting was not found"])
    }
    return (document, targetFolder)
  }

  func append(_ turn: TranscriptTurn) throws {
    meeting?.transcript.append(turn)
    try persist()
  }

  func setFinalTranscript(_ turns: [TranscriptTurn]) throws {
    meeting?.transcript = turns
    meeting?.status = .processing
    try persist()
  }

  /// Marks the active capture as safely saved, then returns everything needed
  /// to finish it without touching a subsequently started meeting.
  func prepareForFinalization() throws -> StoppedMeeting {
    guard var document = meeting, let folder else {
      throw NSError(
        domain: "MeetingStore", code: 10,
        userInfo: [NSLocalizedDescriptionKey: "No recording is available to finalize"])
    }
    document.status = .processing
    meeting = document
    try persist()
    try persistPointer(active: false, captureState: MeetingDocument.Status.processing.rawValue)
    return StoppedMeeting(document: document, folder: folder)
  }

  /// Completes a previously stopped capture by addressing its folder directly.
  /// This deliberately leaves the current-meeting pointer alone: a new capture
  /// may already be in progress.
  func finalizeStoppedMeeting(
    in targetFolder: URL,
    turns: [TranscriptTurn],
    insights: MeetingInsights?
  ) throws -> MeetingDocument {
    var document = try decoder.decode(
      MeetingDocument.self,
      from: Data(contentsOf: stateURL(in: targetFolder)))
    document.transcript = turns
    document.insights = insights
    document.status = .complete
    document.endedAt = Date()
    try persist(document, in: targetFolder)
    let finalFolder = promoteToArchiveIfPossible(document: document, from: targetFolder)
    if meeting?.id == document.id {
      meeting = document
      folder = finalFolder
      try? persistPointer(active: false, captureState: MeetingDocument.Status.complete.rawValue)
    }
    return document
  }

  func markStoppedMeetingFailed(in targetFolder: URL) throws {
    var document = try decoder.decode(
      MeetingDocument.self,
      from: Data(contentsOf: stateURL(in: targetFolder)))
    document.status = .failed
    document.endedAt = Date()
    try persist(document, in: targetFolder)
    if meeting?.id == document.id {
      meeting = document
      folder = targetFolder
      try? persistPointer(active: false, captureState: MeetingDocument.Status.failed.rawValue)
    }
  }

  /// Moves a finished meeting out of the spool into the archive, so a
  /// completed meeting exists in exactly one place. The state file is renamed
  /// to its hidden archive form during the move. When the archive volume is
  /// unavailable the meeting simply stays in the spool; the startup migration
  /// retries it on the next launch.
  @discardableResult
  private func promoteToArchiveIfPossible(document: MeetingDocument, from spoolFolder: URL) -> URL {
    guard document.status == .complete, !isArchiveFolder(spoolFolder) else { return spoolFolder }
    let manager = FileManager.default
    // The archive path is derived from the meeting's own start date rather
    // than the spool's relative path, so a spool folder written in another
    // layout (the week-based experiment) still lands in the archive's
    // canonical `year/month/day` shape.
    let relative = DateFormatter.folderDay.string(from: document.startedAt)
      + "/" + spoolFolder.lastPathComponent
    let destination = archiveRoot.appending(path: relative, directoryHint: .isDirectory)
    do {
      guard !manager.fileExists(atPath: destination.path) else { return spoolFolder }
      try manager.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Hide the state file before the move so the archive never shows a
      // visible meeting.json, not even briefly.
      let visibleState = spoolFolder.appending(path: Self.stateFileName)
      if manager.fileExists(atPath: visibleState.path) {
        try manager.moveItem(
          at: visibleState, to: spoolFolder.appending(path: Self.hiddenStateFileName))
      }
      try manager.moveItem(at: spoolFolder, to: destination)
      try? Data(UUID().uuidString.utf8).write(
        to: destination.appending(path: RemoteSyncService.folderMarker), options: .atomic)
      Task { await sync.enqueue(folder: destination, runHookAfterSync: true) }
      return destination
    } catch {
      // The meeting stays fully usable in the spool; nothing was lost.
      return spoolFolder
    }
  }

  /// Startup migration: every completed meeting still in the spool moves to
  /// the archive. When the archive already holds the same meeting ID, the
  /// archive copy wins (it is the synced, user-visible one) and the spool
  /// duplicate is removed. Interrupted runs simply resume on the next launch.
  @discardableResult
  func promoteCompletedSpoolMeetings() async -> Int {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return 0
    }
    // Only a *complete* archive copy outranks a complete spool copy. The old
    // sync also mirrored in-progress captures into the archive, and such a
    // stale mirror must never win over the finished meeting.
    var archivedComplete = Set<UUID>()
    var archivedStale: [UUID: URL] = [:]
    for url in allStateURLs() where isArchiveFolder(url) {
      guard let data = try? Data(contentsOf: url),
        let document = try? decoder.decode(MeetingDocument.self, from: data)
      else { continue }
      if document.status == .complete {
        archivedComplete.insert(document.id)
      } else {
        archivedStale[document.id] = url.deletingLastPathComponent()
      }
    }

    let spoolCompleted = enumerator.compactMap { $0 as? URL }
      .filter { Self.isStateFile($0) }
      .compactMap { url -> (URL, MeetingDocument)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .complete
        else { return nil }
        return (url.deletingLastPathComponent(), document)
      }

    var movedCount = 0
    for (spoolFolder, document) in spoolCompleted {
      if archivedComplete.contains(document.id) {
        // The archive copy is authoritative; the spool duplicate only wastes
        // space and re-creates the two-truths problem.
        try? manager.removeItem(at: spoolFolder)
        continue
      }
      // A stale non-complete mirror gives way to the finished meeting.
      if let staleFolder = archivedStale[document.id] {
        try? manager.removeItem(at: staleFolder)
      }
      let destination = promoteToArchiveIfPossible(document: document, from: spoolFolder)
      if destination.standardizedFileURL != spoolFolder.standardizedFileURL { movedCount += 1 }
    }
    removeEmptySpoolDayDirectories()
    return movedCount
  }

  /// One-time cleanup of archives written by the mirror-everything sync:
  /// finished meetings get their state file hidden, and stale copies of
  /// meetings that are *not* finished (the old sync mirrored those too) are
  /// removed when the spool still holds the authoritative capture.
  func normalizeArchivedMeetingFolders() async {
    let manager = FileManager.default
    guard root.standardizedFileURL != archiveRoot.standardizedFileURL,
      let enumerator = manager.enumerator(at: archiveRoot, includingPropertiesForKeys: nil)
    else { return }

    let spoolStateURLs = (manager.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL } ?? [])
      .filter { Self.isStateFile($0) }
    var spoolIDs: [UUID: URL] = [:]
    for url in spoolStateURLs {
      guard let data = try? Data(contentsOf: url),
        let document = try? decoder.decode(MeetingDocument.self, from: data)
      else { continue }
      spoolIDs[document.id] = url.deletingLastPathComponent()
    }

    let archiveStateURLs = enumerator.compactMap { $0 as? URL }.filter { Self.isStateFile($0) }
    for url in archiveStateURLs {
      guard let data = try? Data(contentsOf: url),
        let document = try? decoder.decode(MeetingDocument.self, from: data)
      else { continue }
      let archiveFolder = url.deletingLastPathComponent()
      if document.status == .complete {
        // The archive shows only the documents; its state file is hidden.
        if url.lastPathComponent == Self.stateFileName {
          let hidden = archiveFolder.appending(path: Self.hiddenStateFileName)
          if !manager.fileExists(atPath: hidden.path) {
            try? manager.moveItem(at: url, to: hidden)
          }
        }
      } else if spoolIDs[document.id] != nil {
        // A non-complete meeting in the archive is a stale mirror from the
        // old sync. The spool still holds the authoritative capture, so the
        // mirror is safe to drop; it would otherwise shadow the invariant
        // that everything in the archive is finished.
        try? manager.removeItem(at: archiveFolder)
      }
    }
  }

  /// Finished meetings inside `archive`, counted without touching anything.
  func archivedMeetingCount(in archive: URL) -> Int {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: archive, includingPropertiesForKeys: nil) else {
      return 0
    }
    return enumerator.compactMap { $0 as? URL }
      .filter { Self.isStateFile($0) }
      .compactMap { url -> UUID? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .complete
        else { return nil }
        return document.id
      }
      .count
  }

  /// Sizes everything under both roots, split into documents and audio.
  /// Audio is reported separately per root because archive audio (retained on
  /// purpose) and spool audio (recovery tracks for unfinished captures) have
  /// different cleanup stories.
  func storageUsage() -> MeetingStorageUsage {
    let manager = FileManager.default
    var usage = MeetingStorageUsage()
    var seenRoots = Set<String>()
    for base in [root, archiveRoot] {
      guard seenRoots.insert(base.standardizedFileURL.path).inserted else { continue }
      let isArchive = base.standardizedFileURL == archiveRoot.standardizedFileURL
        && root.standardizedFileURL != archiveRoot.standardizedFileURL
      guard let enumerator = manager.enumerator(
        at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
      else { continue }
      for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true
        else { continue }
        let size = Int64(values.fileSize ?? 0)
        if url.pathExtension.lowercased() == "wav" {
          if isArchive {
            usage.archiveAudioBytes += size
          } else {
            usage.recoveryAudioBytes += size
          }
        } else {
          usage.documentBytes += size
        }
      }
    }
    return usage
  }

  /// Deletes every audio file that is safe to delete: retained WAVs of
  /// *complete* meetings in either root. Recovery audio of unfinished
  /// captures is left alone — it is the only path back to a transcript.
  /// Cleaned archive folders re-sync so the remote copy converges.
  func cleanUpAudioFiles() async -> Int64 {
    let manager = FileManager.default
    var freedBytes: Int64 = 0
    for stateURL in allStateURLs() {
      guard let data = try? Data(contentsOf: stateURL),
        let document = try? decoder.decode(MeetingDocument.self, from: data),
        document.status == .complete
      else { continue }
      let targetFolder = stateURL.deletingLastPathComponent()
      var removedAny = false
      for name in ["microphone.wav", "system.wav"] {
        let url = targetFolder.appending(path: name)
        guard manager.fileExists(atPath: url.path) else { continue }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        do {
          try manager.removeItem(at: url)
          freedBytes += size
          removedAny = true
        } catch { continue }
      }
      if removedAny, isArchiveFolder(targetFolder) {
        try? Data(UUID().uuidString.utf8).write(
          to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)
        await sync.enqueue(folder: targetFolder, runHookAfterSync: false)
      }
    }
    return freedBytes
  }

  /// Moves finished meetings from one archive root to another, preserving the
  /// relative `year/month/day/meeting` path. Move-only: content is never
  /// rewritten, and an existing destination folder is left untouched.
  @discardableResult
  func relocateArchivedMeetings(from oldRoot: URL, to newRoot: URL) -> Int {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: oldRoot, includingPropertiesForKeys: nil) else {
      return 0
    }
    let folders = enumerator.compactMap { $0 as? URL }
      .filter { Self.isStateFile($0) }
      .map { $0.deletingLastPathComponent() }
    var movedCount = 0
    for source in folders {
      let relative = source.pathComponents
        .suffix(Self.meetingPathComponentCount).joined(separator: "/")
      let destination = newRoot.appending(path: relative, directoryHint: .isDirectory)
      guard !manager.fileExists(atPath: destination.path) else { continue }
      do {
        try manager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: source, to: destination)
        movedCount += 1
        if folder?.standardizedFileURL == source.standardizedFileURL {
          folder = destination
        }
      } catch { continue }
    }
    return movedCount
  }

  /// Clears out the empty `year/month/day` shells the promotions leave behind.
  /// Only directories holding nothing but Finder's own files are removed.
  private func removeEmptySpoolDayDirectories() {
    let manager = FileManager.default
    let disposable: Set<String> = [".DS_Store"]
    func removeIfEmpty(_ directory: URL) {
      guard let entries = try? manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil),
        entries.allSatisfy({ disposable.contains($0.lastPathComponent) })
      else { return }
      try? manager.removeItem(at: directory)
    }
    guard let years = try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil) else { return }
    for year in years where year.hasDirectoryPath {
      guard year.lastPathComponent.count == 4,
        year.lastPathComponent.allSatisfy(\.isNumber) else { continue }
      let months = (try? manager.contentsOfDirectory(
        at: year, includingPropertiesForKeys: nil)) ?? []
      for month in months where month.hasDirectoryPath {
        let days = (try? manager.contentsOfDirectory(
          at: month, includingPropertiesForKeys: nil)) ?? []
        for day in days where day.hasDirectoryPath { removeIfEmpty(day) }
        removeIfEmpty(month)
      }
      removeIfEmpty(year)
    }
  }

  func replaceCompletedTranscript(_ turns: [TranscriptTurn]) async throws {
    guard var current = meeting, let folder, current.status == .complete else {
      throw NSError(
        domain: "MeetingStore", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Only a completed meeting can be re-transcribed"])
    }
    current.transcript = turns
    current.transcriptDeletedAt = nil
    current.transcriptionVersion += 1
    meeting = current
    try persist()
    await sync.enqueue(folder: folder, runHookAfterSync: true)
  }

  func finalize(insights: MeetingInsights?) throws {
    meeting?.insights = insights
    meeting?.status = .complete
    meeting?.endedAt = Date()
    try persist()
    if let meeting, let folder {
      self.folder = promoteToArchiveIfPossible(document: meeting, from: folder)
    }
    try persistPointer(active: false, captureState: "complete")
  }

  func replaceTranscript(_ turns: [TranscriptTurn], status: MeetingDocument.Status) throws {
    meeting?.transcript = turns
    meeting?.status = status
    if status == .complete || status == .failed { meeting?.endedAt = Date() }
    try persist()
    if status == .complete {
      if let meeting, let folder {
        self.folder = promoteToArchiveIfPossible(document: meeting, from: folder)
      }
      try persistPointer(active: false, captureState: "complete")
    }
  }

  func updateTitle(_ title: String, captureState: String) throws {
    meeting?.title = title
    try persist()
    try persistPointer(active: true, captureState: captureState)
  }

  func heartbeat(captureState: String) throws {
    try persistPointer(active: true, captureState: captureState)
  }

  func setInsights(_ insights: MeetingInsights) throws {
    meeting?.insights = insights
    try persist()
  }

  func setCompletedMeetingInsights(
    _ insights: MeetingInsights,
    meetingID: UUID,
    in targetFolder: URL
  ) throws {
    var document = try decoder.decode(
      MeetingDocument.self,
      from: Data(contentsOf: stateURL(in: targetFolder)))
    guard document.id == meetingID, document.status == .complete else {
      throw NSError(
        domain: "MeetingStore", code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Completed meeting was not found"])
    }
    document.insights = insights
    try persist(document, in: targetFolder)
    if meeting?.id == document.id {
      meeting = document
      folder = targetFolder
    }
  }

  func setCodexThreadID(_ threadID: String, for meetingID: UUID) async throws {
    if meeting?.id == meetingID {
      meeting?.codexThreadID = threadID
      try persist()
      return
    }

    guard let target = allStateURLs()
      .first(where: { url in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data)
        else { return false }
        return document.id == meetingID
      })
    else { throw CocoaError(.fileNoSuchFile) }

    var document = try decoder.decode(MeetingDocument.self, from: Data(contentsOf: target))
    document.codexThreadID = threadID
    try atomicWrite(encoder.encode(document), to: target)
    let targetFolder = target.deletingLastPathComponent()
    try Data(UUID().uuidString.utf8).write(
      to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)
    await sync.enqueue(folder: targetFolder, runHookAfterSync: document.status == .complete)
  }

  func setStatus(_ status: MeetingDocument.Status) throws {
    meeting?.status = status
    if status == .complete || status == .failed { meeting?.endedAt = Date() }
    try persist()
    if status == .processing || status == .complete || status == .failed {
      try persistPointer(active: false, captureState: status.rawValue)
    }
  }

  func audioURL(named name: String) -> URL? { folder?.appending(path: name) }
  func current() -> MeetingDocument? { meeting }
  func currentFolder() -> URL? { folder }

  func removeAudioFiles() throws {
    guard let folder else { return }
    try removeAudioFiles(in: folder)
  }

  func removeAudioFiles(in targetFolder: URL) throws {
    for name in ["microphone.wav", "system.wav"] {
      let url = targetFolder.appending(path: name)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  func latestRecoverableFolder(excluding excludedIDs: Set<UUID> = []) -> URL? {
    recoverableFolders(excluding: excludedIDs).first?.folder
  }

  func recoverableFolder(id: UUID, excluding excludedIDs: Set<UUID> = []) -> URL? {
    recoverableFolders(excluding: excludedIDs).first { $0.document.id == id }?.folder
  }

  private func recoverableFolders(
    excluding excludedIDs: Set<UUID> = []
  ) -> [(folder: URL, document: MeetingDocument, modifiedAt: Date)] {
    // Recovery only ever concerns the spool: a meeting in the archive is
    // complete by definition.
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }
      .filter { Self.isStateFile($0) }
      .compactMap { url -> (URL, MeetingDocument, Date)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          !excludedIDs.contains(document.id),
          document.status == .recording || document.status == .processing
            || document.status == .failed,
          Self.hasRecoverableAudio(in: url.deletingLastPathComponent())
        else { return nil }
        let date =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return (url.deletingLastPathComponent(), document, date)
      }
      .sorted { $0.2 > $1.2 }
  }

  private static func hasRecoverableAudio(in folder: URL) -> Bool {
    ["microphone.wav", "system.wav"].contains { name in
      WavFile.hasMeaningfulSignal(at: folder.appending(path: name))
    }
  }

  private static func hasRetainedAudio(in folder: URL) -> Bool {
    ["microphone.wav", "system.wav"].contains { name in
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: folder.appending(path: name).path)
      return (attributes?[.size] as? NSNumber)?.intValue ?? 0 > 44
    }
  }

  func latestNeedsEnrichmentFolder() -> URL? {
    latestFolder {
      $0.status == .complete && $0.insights == nil
        && $0.transcriptDeletedAt == nil && !$0.transcript.isEmpty
    }
  }

  func completedMeetingFoldersAwaitingInsights(before cutoff: Date) -> [URL] {
    return allStateURLs()
      .compactMap { url -> (URL, Date)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .complete,
          document.insights == nil,
          document.transcriptDeletedAt == nil,
          !document.transcript.isEmpty
        else { return nil }
        let completedAt = document.endedAt ?? document.startedAt
        guard completedAt <= cutoff else { return nil }
        return (url.deletingLastPathComponent(), completedAt)
      }
      .sorted { $0.1 < $1.1 }
      .map(\.0)
  }

  func completedMeetings(on date: Date, calendar: Calendar = .current) -> [MeetingDocument] {
    return allStateURLs()
      .compactMap { url -> MeetingDocument? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .complete,
          calendar.isDate(document.startedAt, inSameDayAs: date)
        else { return nil }
        return document
      }
      .sorted { $0.startedAt > $1.startedAt }
  }

  /// Includes completed meetings plus durable captures that can still be
  /// finalized. This keeps interrupted work visible after an app restart.
  func meetingsForDisplay(on date: Date, calendar: Calendar = .current) -> [MeetingDocument] {
    return allStateURLs()
      .compactMap { url -> MeetingDocument? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          calendar.isDate(document.startedAt, inSameDayAs: date)
        else { return nil }
        if document.status == .complete { return document }
        return Self.hasRetainedAudio(in: url.deletingLastPathComponent()) ? document : nil
      }
      .sorted { $0.startedAt > $1.startedAt }
  }

  func recreateCompletedMeetingNotes(id: UUID) async throws {
    let (document, targetFolder) = try completedMeeting(id: id)

    try atomicWrite(
      Data(MarkdownRenderer.renderMeeting(document).utf8),
      to: targetFolder.appending(path: "meeting.md"))
    try Data(UUID().uuidString.utf8).write(
      to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)
    await sync.enqueue(folder: targetFolder, runHookAfterSync: true)
  }

  func normalizeCompletedMeetingFolders() async {
    let mismatches = allStateURLs()
      .compactMap { stateURL -> (UUID, String)? in
        guard let data = try? Data(contentsOf: stateURL),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .complete
        else { return nil }
        let safeTitle = document.title.filenameSafe.isEmpty ? "meeting" : document.title.filenameSafe
        let expectedName =
          "\(DateFormatter.fileTime.string(from: document.startedAt))-\(safeTitle)-\(document.id.uuidString.prefix(8))"
        guard stateURL.deletingLastPathComponent().lastPathComponent != expectedName else {
          return nil
        }
        return (document.id, document.title)
      }
    for (id, title) in mismatches {
      try? await renameCompletedMeeting(id: id, title: title)
    }
  }

  /// Rewrites older meeting documents into the current neutral-speaker schema.
  func normalizeMeetingDocuments() async {
    let stateURLs = allStateURLs()

    for stateURL in stateURLs {
      guard let data = try? Data(contentsOf: stateURL),
        var document = try? decoder.decode(MeetingDocument.self, from: data)
      else { continue }
      let hasLegacySchema = data.range(of: Data("\"speakerNames\"".utf8)) != nil
        || data.range(of: Data("\"transcriptFinalized\"".utf8)) != nil
      let hasAttributedTurn = document.transcript.contains { $0.speaker != "Unknown" }
      guard hasLegacySchema || hasAttributedTurn else { continue }

      document.transcript = document.transcript.map { turn in
        var updated = turn
        updated.speaker = "Unknown"
        return updated
      }
      document.transcriptionVersion += 1

      let targetFolder = stateURL.deletingLastPathComponent()
      if document.status == .complete {
        try? persistTranscriptArtifact(for: document, in: targetFolder)
        try? atomicWrite(
          Data(MarkdownRenderer.renderMeeting(document).utf8),
          to: targetFolder.appending(path: "meeting.md"))
      } else {
        try? atomicWrite(
          Data(MarkdownRenderer.renderLive(document).utf8),
          to: targetFolder.appending(path: "live.md"))
      }
      try? atomicWrite(encoder.encode(document), to: stateURL)
      try? Data(UUID().uuidString.utf8).write(
        to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)

      if meeting?.id == document.id {
        meeting = document
        folder = targetFolder
      }
      await sync.enqueue(folder: targetFolder, runHookAfterSync: document.status == .complete)
    }
  }

  /// Removes detailed meeting data while preserving the structured meeting note.
  /// Each changed folder is re-synced with deletion enabled, so archive copies
  /// converge on the same retained data.
  func purgeExpiredTranscripts(before cutoff: Date, now: Date = Date()) async throws -> Int {
    let manager = FileManager.default
    let targets = allStateURLs()
      .compactMap { stateURL -> (URL, MeetingDocument)? in
        guard let data = try? Data(contentsOf: stateURL),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .complete,
          (document.endedAt ?? document.startedAt) < cutoff
        else { return nil }
        return (stateURL.deletingLastPathComponent(), document)
      }

    var purgedCount = 0
    for (targetFolder, original) in targets {
      let transcriptURL = targetFolder.appending(path: "transcript.md")
      let audioURLs = ["microphone.wav", "system.wav"].map { targetFolder.appending(path: $0) }
      let hasDetailedData = !original.transcript.isEmpty
        || manager.fileExists(atPath: transcriptURL.path)
        || audioURLs.contains { manager.fileExists(atPath: $0.path) }
        || original.transcriptDeletedAt == nil
      guard hasDetailedData else { continue }

      var document = original
      document.transcript = []
      document.transcriptDeletedAt = document.transcriptDeletedAt ?? now
      try atomicWrite(
        encoder.encode(document), to: stateURL(in: targetFolder))
      try atomicWrite(
        Data(MarkdownRenderer.renderMeeting(document).utf8),
        to: targetFolder.appending(path: "meeting.md"))
      for url in [transcriptURL] + audioURLs where manager.fileExists(atPath: url.path) {
        try manager.removeItem(at: url)
      }
      try Data(UUID().uuidString.utf8).write(
        to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)

      if meeting?.id == document.id {
        meeting = document
        folder = targetFolder
      }
      await sync.enqueue(folder: targetFolder, runHookAfterSync: true)
      purgedCount += 1
    }
    return purgedCount
  }

  func enqueueCompleteArchive() async {
    let manager = FileManager.default
    if manager.fileExists(atPath: root.appending(path: "current.json").path) {
      try? Data(UUID().uuidString.utf8).write(
        to: root.appending(path: RemoteSyncService.pointerMarker), options: .atomic)
      await sync.enqueuePointer(root.appending(path: "current.json"))
    }
    for stateURL in allStateURLs() {
      guard let data = try? Data(contentsOf: stateURL),
        let document = try? decoder.decode(MeetingDocument.self, from: data),
        document.status == .complete
      else { continue }
      let folder = stateURL.deletingLastPathComponent()
      try? Data(UUID().uuidString.utf8).write(
        to: folder.appending(path: RemoteSyncService.folderMarker), options: .atomic)
      await sync.enqueue(folder: folder, runHookAfterSync: true)
    }
  }

  func deleteMeeting(id: UUID) async throws {
    let manager = FileManager.default
    let target = allStateURLs()
      .compactMap { url -> (URL, MeetingDocument)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.id == id
        else { return nil }
        return (url.deletingLastPathComponent(), document)
      }
      .first
    guard let (targetFolder, document) = target else {
      throw NSError(
        domain: "MeetingStore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Meeting was not found"])
    }

    let pointerURL = root.appending(path: "current.json")
    let pointer = (try? Data(contentsOf: pointerURL))
      .flatMap { try? decoder.decode(CurrentMeetingPointer.self, from: $0) }
    let clearPointer = pointer?.meetingID == id && pointer?.active == false

    try await sync.delete(
      folder: targetFolder, relativeTo: baseRoot(of: targetFolder), clearPointer: clearPointer)
    // For an archive-resident meeting the sync delete already removed this
    // exact folder, so a second removal must tolerate its absence.
    if manager.fileExists(atPath: targetFolder.path) {
      try manager.removeItem(at: targetFolder)
    }
    if clearPointer {
      try? manager.removeItem(at: pointerURL)
      try? manager.removeItem(at: root.appending(path: RemoteSyncService.pointerMarker))
    }
    if document.id == meeting?.id {
      meeting = nil
      folder = nil
    }
  }

  func renameCompletedMeeting(id: UUID, title: String) async throws {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else {
      throw NSError(
        domain: "MeetingStore", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Meeting title cannot be empty"])
    }
    let manager = FileManager.default
    let target = allStateURLs()
      .compactMap { url -> (URL, MeetingDocument)? in
        guard let data = try? Data(contentsOf: url),
          var document = try? decoder.decode(MeetingDocument.self, from: data),
          document.id == id,
          document.status == .complete
        else { return nil }
        document.title = cleanTitle
        document.calendar?.organizer = nil
        document.calendar?.participants = []
        return (url.deletingLastPathComponent(), document)
      }
      .first
    guard let (targetFolder, document) = target else {
      throw NSError(
        domain: "MeetingStore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Completed meeting was not found"])
    }

    try persistTranscriptArtifact(for: document, in: targetFolder)
    try atomicWrite(
      Data(MarkdownRenderer.renderMeeting(document).utf8),
      to: targetFolder.appending(path: "meeting.md"))
    try atomicWrite(encoder.encode(document), to: stateURL(in: targetFolder))
    try Data(UUID().uuidString.utf8).write(
      to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)

    let base = baseRoot(of: targetFolder)
    let oldRelativePath = targetFolder.path.replacingOccurrences(of: base.path + "/", with: "")
    let safeTitle = cleanTitle.filenameSafe.isEmpty ? "meeting" : cleanTitle.filenameSafe
    let renamedFolder = targetFolder.deletingLastPathComponent().appending(
      path: "\(DateFormatter.fileTime.string(from: document.startedAt))-\(safeTitle)-\(document.id.uuidString.prefix(8))",
      directoryHint: .isDirectory)
    let folderChanged = renamedFolder.standardizedFileURL != targetFolder.standardizedFileURL
    if folderChanged {
      guard !manager.fileExists(atPath: renamedFolder.path) else {
        throw NSError(
          domain: "MeetingStore", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "A meeting folder with that name already exists"])
      }
      try manager.moveItem(at: targetFolder, to: renamedFolder)
      try Data(oldRelativePath.utf8).write(
        to: renamedFolder.appending(path: RemoteSyncService.renameMarker), options: .atomic)
    }
    let finalFolder = folderChanged ? renamedFolder : targetFolder
    let finalRelativePath = finalFolder.path.replacingOccurrences(of: base.path + "/", with: "")

    let pointerURL = root.appending(path: "current.json")
    if let data = try? Data(contentsOf: pointerURL),
      var pointer = try? decoder.decode(CurrentMeetingPointer.self, from: data),
      pointer.meetingID == id
    {
      pointer.title = cleanTitle
      pointer.relativeFolder = finalRelativePath
      pointer.updatedAt = Date()
      try atomicWrite(encoder.encode(pointer), to: pointerURL)
      try Data(UUID().uuidString.utf8).write(
        to: root.appending(path: RemoteSyncService.pointerMarker), options: .atomic)
      await sync.enqueuePointer(pointerURL)
    }

    if meeting?.id == id {
      meeting = document
      folder = finalFolder
    }
    if folderChanged {
      await sync.enqueueRename(
        folder: finalFolder, previousFolder: targetFolder,
        previousRelativePath: oldRelativePath)
    } else {
      await sync.enqueue(folder: finalFolder, runHookAfterSync: true)
    }
  }

  private func latestFolder(where predicate: (MeetingDocument) -> Bool) -> URL? {
    return allStateURLs(keys: [.contentModificationDateKey])
      .compactMap { url -> (URL, Date)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          predicate(document)
        else { return nil }
        let date =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return (url.deletingLastPathComponent(), date)
      }
      .max(by: { $0.1 < $1.1 })?.0
  }

  private func persist() throws {
    guard let meeting, let folder else { return }
    try persist(meeting, in: folder)
  }

  private func persist(_ meeting: MeetingDocument, in folder: URL) throws {
    let liveURL = folder.appending(path: "live.md")
    let transcriptURL = folder.appending(path: "transcript.md")
    let meetingURL = folder.appending(path: "meeting.md")
    let stateURL = stateURL(in: folder)
    if meeting.status == .complete {
      if meeting.transcriptDeletedAt == nil {
        try atomicWrite(Data(MarkdownRenderer.renderTranscript(meeting).utf8), to: transcriptURL)
      } else if FileManager.default.fileExists(atPath: transcriptURL.path) {
        try FileManager.default.removeItem(at: transcriptURL)
      }
      try atomicWrite(Data(MarkdownRenderer.renderMeeting(meeting).utf8), to: meetingURL)
      if FileManager.default.fileExists(atPath: liveURL.path) {
        try FileManager.default.removeItem(at: liveURL)
      }
    } else {
      try atomicWrite(Data(MarkdownRenderer.renderLive(meeting).utf8), to: liveURL)
    }
    try atomicWrite(encoder.encode(meeting), to: stateURL)
    try Data(UUID().uuidString.utf8).write(
      to: folder.appending(path: RemoteSyncService.folderMarker), options: .atomic)
    Task {
      await sync.enqueue(
        folder: folder,
        runHookAfterSync: meeting.status == .complete
      )
    }
  }

  private func persistPointer(active: Bool, captureState: String?) throws {
    guard let meeting, let folder else { return }
    let relative = folder.path.replacingOccurrences(of: baseRoot(of: folder).path + "/", with: "")
    let pointer = CurrentMeetingPointer(
      active: active, meetingID: meeting.id, title: meeting.title,
      relativeFolder: relative, startedAt: meeting.startedAt, updatedAt: Date(),
      captureState: captureState
    )
    let url = root.appending(path: "current.json")
    try atomicWrite(encoder.encode(pointer), to: url)
    try Data(UUID().uuidString.utf8).write(
      to: root.appending(path: RemoteSyncService.pointerMarker), options: .atomic)
    Task { await sync.enqueuePointer(url) }
  }

  private func atomicWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = url.appendingPathExtension("tmp")
    try data.write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }

  private func persistTranscriptArtifact(for meeting: MeetingDocument, in folder: URL) throws {
    let transcriptURL = folder.appending(path: "transcript.md")
    if meeting.transcriptDeletedAt == nil {
      try atomicWrite(Data(MarkdownRenderer.renderTranscript(meeting).utf8), to: transcriptURL)
    } else if FileManager.default.fileExists(atPath: transcriptURL.path) {
      try FileManager.default.removeItem(at: transcriptURL)
    }
  }
}

extension DateFormatter {
  fileprivate static let folderDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
  fileprivate static let fileTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HHmm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()
}
