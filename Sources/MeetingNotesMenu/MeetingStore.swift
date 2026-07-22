import Foundation

actor MeetingStore {
  private let root: URL
  private let sync: RemoteSyncService
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var meeting: MeetingDocument?
  private var folder: URL?

  init(root: URL, sync: RemoteSyncService) {
    self.root = root
    self.sync = sync
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
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
    let data = try Data(contentsOf: folder.appending(path: "meeting.json"))
    let document = try decoder.decode(MeetingDocument.self, from: data)
    self.folder = folder
    meeting = document
    return document
  }

  func loadCompletedMeeting(id: UUID) throws -> (document: MeetingDocument, folder: URL) {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { throw CocoaError(.fileNoSuchFile) }
    let target = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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
    meeting = document
    folder = targetFolder
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
    try persistPointer(active: false, captureState: "complete")
  }

  func replaceTranscript(_ turns: [TranscriptTurn], status: MeetingDocument.Status) throws {
    meeting?.transcript = turns
    meeting?.status = status
    if status == .complete || status == .failed { meeting?.endedAt = Date() }
    try persist()
    if status == .complete { try persistPointer(active: false, captureState: "complete") }
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

  func setCodexThreadID(_ threadID: String, for meetingID: UUID) async throws {
    if meeting?.id == meetingID {
      meeting?.codexThreadID = threadID
      try persist()
      return
    }

    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { throw CocoaError(.fileNoSuchFile) }
    guard let target = enumerator.compactMap({ $0 as? URL })
      .filter({ $0.lastPathComponent == "meeting.json" })
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
    for name in ["microphone.wav", "system.wav"] {
      let url = folder.appending(path: name)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  func latestRecoverableFolder() -> URL? {
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    return enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
      .compactMap { url -> (URL, Date)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.status == .recording || document.status == .processing
            || document.status == .failed,
          Self.hasRecoverableAudio(in: url.deletingLastPathComponent())
        else { return nil }
        let date =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return (url.deletingLastPathComponent(), date)
      }
      .max(by: { $0.1 < $1.1 })?.0
  }

  private static func hasRecoverableAudio(in folder: URL) -> Bool {
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
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return []
    }
    return enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return []
    }
    return enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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

  func recreateCompletedMeetingNotes(id: UUID) async throws {
    let (document, targetFolder) = try loadCompletedMeeting(id: id)

    try atomicWrite(
      Data(MarkdownRenderer.renderMeeting(document).utf8),
      to: targetFolder.appending(path: "meeting.md"))
    try Data(UUID().uuidString.utf8).write(
      to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)
    await sync.enqueue(folder: targetFolder, runHookAfterSync: true)
  }

  func normalizeCompletedMeetingFolders() async {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return
    }
    let mismatches = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return
    }
    let stateURLs = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }

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
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return 0
    }

    let targets = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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
        encoder.encode(document), to: targetFolder.appending(path: "meeting.json"))
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
    let stateURLs = (try? manager.subpathsOfDirectory(atPath: root.path))?
      .filter { URL(fileURLWithPath: $0).lastPathComponent == "meeting.json" }
      .map { root.appending(path: $0) } ?? []
    for stateURL in stateURLs {
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

  func deleteCompletedMeeting(id: UUID) async throws {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let target = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
      .compactMap { url -> (URL, MeetingDocument)? in
        guard let data = try? Data(contentsOf: url),
          let document = try? decoder.decode(MeetingDocument.self, from: data),
          document.id == id,
          document.status == .complete
        else { return nil }
        return (url.deletingLastPathComponent(), document)
      }
      .first
    guard let (targetFolder, document) = target else {
      throw NSError(
        domain: "MeetingStore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Completed meeting was not found"])
    }

    let pointerURL = root.appending(path: "current.json")
    let pointer = (try? Data(contentsOf: pointerURL))
      .flatMap { try? decoder.decode(CurrentMeetingPointer.self, from: $0) }
    let clearPointer = pointer?.meetingID == id && pointer?.active == false

    try await sync.delete(folder: targetFolder, relativeTo: root, clearPointer: clearPointer)
    try manager.removeItem(at: targetFolder)
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
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let target = enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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
    try atomicWrite(encoder.encode(document), to: targetFolder.appending(path: "meeting.json"))
    try Data(UUID().uuidString.utf8).write(
      to: targetFolder.appending(path: RemoteSyncService.folderMarker), options: .atomic)

    let oldRelativePath = targetFolder.path.replacingOccurrences(of: root.path + "/", with: "")
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
    let finalRelativePath = finalFolder.path.replacingOccurrences(of: root.path + "/", with: "")

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
    let manager = FileManager.default
    guard
      let enumerator = manager.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    return enumerator.compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "meeting.json" }
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
    let liveURL = folder.appending(path: "live.md")
    let transcriptURL = folder.appending(path: "transcript.md")
    let meetingURL = folder.appending(path: "meeting.md")
    let stateURL = folder.appending(path: "meeting.json")
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
    let relative = folder.path.replacingOccurrences(of: root.path + "/", with: "")
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
