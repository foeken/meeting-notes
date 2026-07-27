import Foundation

actor RemoteSyncService {
  static let folderMarker = ".remote-sync-pending"
  static let renameMarker = ".remote-rename-from"
  static let pointerMarker = ".current-sync-pending"

  struct Configuration: Equatable, Sendable {
    static let defaultLocalPath = "~/Documents/Meetings Notes"
    /// Prefilled so the expected `Name: value` shape is obvious. Edit or clear
    /// these before pointing the hook at a real endpoint.
    static let defaultHTTPHookHeaders = """
      Authorization: Bearer sk-example-token
      X-Source: Meeting Notes
      """

    var destination: Destination
    var host: String
    var path: String
    var localPath: String
    var enabled: Bool
    var includeAudio: Bool
    var postMeetingHookLocation: HookLocation
    var postMeetingHookCommand: String
    var httpHookURL: String
    var httpHookHeaders: String
    var httpHookPayload: HookPayload

    var remoteSyncEnabled: Bool {
      get { destination == .remote }
      set { destination = newValue ? .remote : .local }
    }

    init(
      destination: Destination = .remote,
      host: String,
      path: String,
      localPath: String = Configuration.defaultLocalPath,
      enabled: Bool,
      includeAudio: Bool = false,
      postMeetingHookLocation: HookLocation = .disabled,
      postMeetingHookCommand: String = "",
      httpHookURL: String = "",
      httpHookHeaders: String = Configuration.defaultHTTPHookHeaders,
      httpHookPayload: HookPayload = .meetingNotes
    ) {
      self.destination = destination
      self.host = host
      self.path = path
      self.localPath = localPath
      self.enabled = enabled
      self.includeAudio = includeAudio
      self.postMeetingHookLocation = postMeetingHookLocation
      self.postMeetingHookCommand = postMeetingHookCommand
      self.httpHookURL = httpHookURL
      self.httpHookHeaders = httpHookHeaders
      self.httpHookPayload = httpHookPayload
    }

    static var defaults: Configuration {
      Configuration(
        destination: .local,
        host: "",
        path: "~/MeetingNotes",
        localPath: defaultLocalPath,
        enabled: true,
        includeAudio: false,
        postMeetingHookLocation: .disabled,
        postMeetingHookCommand: "",
        httpHookURL: "",
        httpHookHeaders: defaultHTTPHookHeaders,
        httpHookPayload: .meetingNotes
      )
    }
  }

  private var configuration: Configuration
  private struct SyncOptions: Sendable {
    var runHookAfterSync = false
    var previousRelativePath: String?
  }
  private var pending: [URL: SyncOptions] = [:]
  private var renamedFolders: [URL: URL] = [:]
  private var pendingPointer: URL?
  private var worker: Task<Void, Never>?
  private var isFlushing = false
  private(set) var lastError: String?
  private(set) var lastSyncAt: Date?

  init(configuration: Configuration = .defaults) {
    self.configuration = configuration
  }

  func update(configuration: Configuration) {
    self.configuration = configuration
    lastError = nil
  }

  /// Re-validates the active configuration before any ssh/rsync invocation so
  /// unvalidated values (empty or option-like host/path, stale settings) can
  /// never reach a command line.
  private func validatedRemoteConfiguration() throws -> Configuration {
    let config = configuration
    if let error = config.validationError {
      throw NSError(
        domain: "RemoteSync", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Archive settings are invalid: \(error)"])
    }
    if config.remoteSyncEnabled {
      let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = config.path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !host.isEmpty, !host.hasPrefix("-"), !path.isEmpty, !path.hasPrefix("-") else {
        throw NSError(
          domain: "RemoteSync", code: 6,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Archive settings are invalid: the SSH host and remote path must not be empty or start with “-”."
          ])
      }
    }
    return config
  }

  func enqueue(folder: URL, runHookAfterSync: Bool = false) {
    guard configuration.enabled else { return }
    var options = pending[folder] ?? SyncOptions()
    options.runHookAfterSync = options.runHookAfterSync || runHookAfterSync
    pending[folder] = options
    guard worker == nil, !isFlushing else { return }
    worker = Task {
      try? await Task.sleep(for: .milliseconds(750))
      await flush()
    }
  }

  func enqueueRename(folder: URL, previousFolder: URL, previousRelativePath: String) {
    guard configuration.enabled else {
      try? FileManager.default.removeItem(at: folder.appending(path: Self.folderMarker))
      try? FileManager.default.removeItem(at: folder.appending(path: Self.renameMarker))
      return
    }
    renamedFolders[previousFolder] = folder
    let previousOptions = pending.removeValue(forKey: previousFolder)
    var options = pending[folder] ?? SyncOptions()
    options.runHookAfterSync = options.runHookAfterSync || (previousOptions?.runHookAfterSync ?? false)
    options.runHookAfterSync = true
    options.previousRelativePath = previousRelativePath
    pending[folder] = options
    guard worker == nil, !isFlushing else { return }
    worker = Task {
      try? await Task.sleep(for: .milliseconds(250))
      await flush()
    }
  }

  func enqueuePointer(_ file: URL) {
    guard configuration.enabled else { return }
    pendingPointer = file
    guard worker == nil, !isFlushing else { return }
    worker = Task {
      try? await Task.sleep(for: .milliseconds(250))
      await flush()
    }
  }

  func delete(folder: URL, relativeTo root: URL, clearPointer: Bool) async throws {
    guard configuration.enabled else {
      throw NSError(
        domain: "RemoteSync", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Remote sync is disabled"])
    }

    let rootPath = root.standardizedFileURL.path
    let folderPath = folder.standardizedFileURL.path
    guard folderPath.hasPrefix(rootPath + "/") else {
      throw NSError(
        domain: "RemoteSync", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Meeting folder is outside the local archive"])
    }
    let relative = String(folderPath.dropFirst(rootPath.count + 1))
    guard Self.isSafeMeetingPath(relative) else {
      throw NSError(
        domain: "RemoteSync", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Meeting folder path is invalid"])
    }

    pending.removeValue(forKey: folder)
    try await deleteArchiveFolder(relative: relative, clearPointer: clearPointer)
    try await runPostMeetingHook()
  }

  func flush() async {
    guard !isFlushing else { return }
    isFlushing = true
    defer { isFlushing = false }
    worker = nil
    guard configuration.enabled else { return }
    let batch = pending
    pending.removeAll()
    var errors: [String] = []
    for (folder, options) in batch.sorted(by: { $0.key.path < $1.key.path }) {
      let marker = folder.appending(path: Self.folderMarker)
      let revision = try? Data(contentsOf: marker)
      do {
        try await sync(folder: folder)
        if let previousRelativePath = options.previousRelativePath {
          try await deleteArchiveFolder(relative: previousRelativePath, clearPointer: false)
        }
        if options.runHookAfterSync { try await runPostMeetingHook(folder: folder) }
        if (try? Data(contentsOf: marker)) == revision {
          try? FileManager.default.removeItem(at: marker)
          if options.previousRelativePath != nil {
            try? FileManager.default.removeItem(at: folder.appending(path: Self.renameMarker))
            renamedFolders = renamedFolders.filter { $0.value != folder }
          }
        } else {
          let retryFolder = renamedFolders[folder] ?? folder
          var retry = pending[retryFolder] ?? SyncOptions()
          retry.runHookAfterSync = retry.runHookAfterSync || options.runHookAfterSync
          retry.previousRelativePath = options.previousRelativePath ?? retry.previousRelativePath
          pending[retryFolder] = retry
        }
        lastSyncAt = Date()
      } catch {
        errors.append(error.localizedDescription)
        let retryFolder = renamedFolders[folder] ?? folder
        var retry = pending[retryFolder] ?? SyncOptions()
        retry.runHookAfterSync = retry.runHookAfterSync || options.runHookAfterSync
        retry.previousRelativePath = options.previousRelativePath ?? retry.previousRelativePath
        pending[retryFolder] = retry
      }
    }
    if let pointer = pendingPointer {
      pendingPointer = nil
      let marker = pointer.deletingLastPathComponent().appending(path: Self.pointerMarker)
      let revision = try? Data(contentsOf: marker)
      do {
        try await syncPointer(pointer)
        if (try? Data(contentsOf: marker)) == revision {
          try? FileManager.default.removeItem(at: marker)
        } else {
          pendingPointer = pointer
        }
        lastSyncAt = Date()
      } catch {
        errors.append(error.localizedDescription)
        pendingPointer = pointer
      }
    }
    lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")
    if !pending.isEmpty || pendingPointer != nil, worker == nil {
      worker = Task {
        try? await Task.sleep(for: .seconds(10))
        await flush()
      }
    }
  }

  /// Restore work that survived an app quit or a Mac restart.
  func reconcile(root: URL) {
    guard configuration.enabled else { return }
    let manager = FileManager.default
    if manager.fileExists(atPath: root.appending(path: Self.pointerMarker).path) {
      pendingPointer = root.appending(path: "current.json")
    }
    if let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let marker as URL in enumerator where marker.lastPathComponent == Self.folderMarker {
        let folder = marker.deletingLastPathComponent()
        let state = folder.appending(path: "meeting.json")
        let complete =
          (try? Data(contentsOf: state))
          .flatMap { try? JSONDecoder.meetingDecoder.decode(MeetingDocument.self, from: $0) }?
          .status == .complete
        var options = pending[folder] ?? SyncOptions()
        options.runHookAfterSync = options.runHookAfterSync || complete
        let renameMarker = folder.appending(path: Self.renameMarker)
        if let data = try? Data(contentsOf: renameMarker),
          let previous = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          Self.isSafeMeetingPath(previous)
        {
          options.previousRelativePath = previous
          options.runHookAfterSync = true
        }
        pending[folder] = options
      }
    }
    scheduleIfNeeded(delay: .milliseconds(100))
  }

  private func scheduleIfNeeded(delay: Duration) {
    guard worker == nil, !isFlushing, !pending.isEmpty || pendingPointer != nil else { return }
    worker = Task {
      try? await Task.sleep(for: delay)
      await flush()
    }
  }

  private func syncPointer(_ file: URL) async throws {
    let config = try validatedRemoteConfiguration()
    let archive = try localArchiveURL(for: config)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try await run(
      "/usr/bin/rsync",
      ["-az", "--partial", file.path, archive.appending(path: "current.json").path])
    if config.remoteSyncEnabled {
      try await run(
        "/usr/bin/ssh",
        strictSSHArguments(host: config.host) + ["mkdir", "-p", config.path])
      try await run(
        "/usr/bin/rsync",
        [
          "-az", "--partial", "-e", strictSSHCommand, file.path,
          "\(config.host):\(config.path)/current.json",
        ])
    }
  }

  /// `folder` is the meeting that changed, when one is known. The HTTP hook
  /// needs it to read the document it posts; the command hook does not.
  private func runPostMeetingHook(folder: URL? = nil) async throws {
    try await runPostMeetingHook(configuration: configuration, folder: folder)
  }

  /// Tests only the command hook, so the Test button next to it cannot fire an
  /// unrelated HTTP request.
  func testPostMeetingHook(configuration: Configuration) async throws {
    try await runCommandHook(configuration: configuration)
  }

  /// Sends a single test request without touching the command hook.
  func testPostMeetingHTTPHook(configuration: Configuration) async throws {
    try await runHTTPHook(configuration: configuration, folder: nil)
  }

  private func runPostMeetingHook(
    configuration config: Configuration, folder: URL?
  ) async throws {
    // Both hooks are independent, so a failing command hook must not stop the
    // HTTP hook from firing (and the reverse).
    var failure: Error?
    do { try await runCommandHook(configuration: config) } catch { failure = error }
    do { try await runHTTPHook(configuration: config, folder: folder) } catch {
      failure = failure ?? error
    }
    if let failure { throw failure }
  }

  private func runCommandHook(configuration config: Configuration) async throws {
    let command = config.postMeetingHookCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, config.postMeetingHookLocation != .disabled else { return }
    switch config.postMeetingHookLocation {
    case .disabled:
      return
    case .remote:
      // Stale hook settings can point at a remote that is no longer configured.
      // Treat that as a no-op instead of handing ssh an empty or unwanted host.
      let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
      guard config.remoteSyncEnabled, !host.isEmpty else {
        lastError = "Post-meeting hook skipped: remote sync is not configured."
        return
      }
      guard !host.hasPrefix("-"), !config.path.hasPrefix("-") else {
        lastError = "Post-meeting hook skipped: the SSH host or path is invalid."
        return
      }
      try await run(
        "/usr/bin/ssh",
        strictSSHArguments(host: host) + ["cd -- \(config.path) && \(command)"])
    case .local:
      let archive = (config.localPath as NSString).expandingTildeInPath
      try await run("/bin/zsh", ["-lc", "cd -- \(Self.shellQuote(archive)) && \(command)"])
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Posts the chosen finished document to a user-supplied endpoint. The body
  /// is the Markdown file itself, so a receiver can store it verbatim.
  private func runHTTPHook(configuration config: Configuration, folder: URL?) async throws {
    let rawURL = config.httpHookURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawURL.isEmpty else { return }
    if let urlError = Configuration.httpHookURLError(rawURL) {
      lastError = "HTTP hook skipped: \(urlError)"
      return
    }
    guard let url = URL(string: rawURL) else { return }

    let document = try httpHookDocument(configuration: config, folder: folder)
    guard let document else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
    for (name, value) in document.metadataHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    // User headers win, so Content-Type and friends can be overridden.
    for header in Configuration.parseHookHeaders(config.httpHookHeaders) {
      request.setValue(header.value, forHTTPHeaderField: header.name)
    }
    request.httpBody = Data(document.body.utf8)

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw NSError(
        domain: "HTTPHook", code: http.statusCode,
        userInfo: [
          NSLocalizedDescriptionKey:
            "HTTP hook returned status \(http.statusCode)."
        ])
    }
  }

  private struct HTTPHookDocument {
    let fileName: String
    let body: String
    let metadataHeaders: [(String, String)]
  }

  /// Header values must stay on one line and within ASCII. Anything else is
  /// percent-encoded so a meeting title with accents or emoji still travels.
  static func sanitizedHeaderValue(_ value: String) -> String {
    let flattened = value
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !flattened.allSatisfy({ $0.isASCII }) else { return flattened }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -._~:/?#[]@!$&'()*+,;="))
    return flattened.addingPercentEncoding(withAllowedCharacters: allowed) ?? flattened
  }

  /// The metadata every request carries, so a receiver can file the document
  /// without parsing the Markdown first.
  static func metadataHeaders(
    fileName: String, meetingPath: String?, meeting: MeetingDocument?
  ) -> [(String, String)] {
    let formatter = ISO8601DateFormatter()
    var headers: [(String, String)] = [("X-Meeting-Notes-File", fileName)]
    if let meetingPath { headers.append(("X-Meeting-Notes-Folder", meetingPath)) }
    guard let meeting else { return headers }
    headers.append(("X-Meeting-Notes-Id", meeting.id.uuidString))
    headers.append(("X-Meeting-Notes-Title", sanitizedHeaderValue(meeting.title)))
    headers.append(("X-Meeting-Notes-Started-At", formatter.string(from: meeting.startedAt)))
    if let endedAt = meeting.endedAt {
      headers.append(("X-Meeting-Notes-Ended-At", formatter.string(from: endedAt)))
      let duration = Int(endedAt.timeIntervalSince(meeting.startedAt).rounded())
      if duration >= 0 {
        headers.append(("X-Meeting-Notes-Duration-Seconds", String(duration)))
      }
    }
    let participants = (meeting.calendar?.participants ?? []).map(\.name)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if !participants.isEmpty {
      headers.append(
        ("X-Meeting-Notes-Participants", sanitizedHeaderValue(participants.joined(separator: ", ")))
      )
    }
    return headers
  }

  private func httpHookDocument(
    configuration config: Configuration, folder: URL?
  ) throws -> HTTPHookDocument? {
    let fileName = config.httpHookPayload.fileName
    guard let folder else {
      // A test run has no meeting yet; send a recognizable sample instead.
      return HTTPHookDocument(
        fileName: fileName,
        body: "# Meeting Notes test\n\nThis is a test request from Meeting Notes.\n",
        metadataHeaders: Self.metadataHeaders(
          fileName: fileName, meetingPath: nil, meeting: nil))
    }
    let file = folder.appending(path: fileName)
    guard let body = try? String(contentsOf: file, encoding: .utf8) else {
      // A deleted meeting, or a payload this meeting does not have (for
      // example a purged transcript), is not a failure worth retrying.
      return nil
    }
    let meeting = (try? Data(contentsOf: folder.appending(path: "meeting.json")))
      .flatMap { try? JSONDecoder.meetingDecoder.decode(MeetingDocument.self, from: $0) }
    return HTTPHookDocument(
      fileName: fileName,
      body: body,
      metadataHeaders: Self.metadataHeaders(
        fileName: fileName,
        meetingPath: folder.pathComponents.suffix(4).joined(separator: "/"),
        meeting: meeting))
  }

  static func isSafeMeetingPath(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 4,
      components[0].count == 4,
      components[1].count == 2,
      components[2].count == 2,
      components[0].allSatisfy(\.isNumber),
      components[1].allSatisfy(\.isNumber),
      components[2].allSatisfy(\.isNumber),
      !components[3].isEmpty
    else { return false }
    return components[3].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
  }

  private func sync(folder: URL) async throws {
    let config = try validatedRemoteConfiguration()
    let tail = folder.pathComponents.suffix(4).joined(separator: "/")
    let localTarget = try localArchiveURL(for: config).appending(
      path: tail, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: localTarget, withIntermediateDirectories: true)
    try await sync(folder: folder, destination: localTarget.path + "/", remotely: false)
    if config.includeAudio {
      try Self.makeRetainedAudioVisible(in: localTarget)
    }

    if config.remoteSyncEnabled {
      let remoteFolder = "\(config.path)/\(tail)/"
      try await run(
        "/usr/bin/ssh",
        strictSSHArguments(host: config.host) + ["mkdir", "-p", remoteFolder])
      try await sync(
        folder: folder, destination: "\(config.host):\(remoteFolder)", remotely: true)
    }
  }

  private func sync(folder: URL, destination: String, remotely: Bool) async throws {
    let config = configuration
    var arguments = [
      "-az", "--partial", "--delete-delay", "--delete-excluded", "--exclude", "*.tmp",
    ]
    if !config.includeAudio { arguments += ["--exclude", "*.wav"] }
    if remotely { arguments += ["-e", strictSSHCommand] }
    arguments += ["--exclude", Self.folderMarker]
    arguments += ["--exclude", Self.renameMarker]
    arguments += [folder.path + "/", destination]
    try await run("/usr/bin/rsync", arguments)
  }

  static func makeRetainedAudioVisible(in folder: URL) throws {
    let manager = FileManager.default
    for name in ["microphone.wav", "system.wav"] {
      var url = folder.appending(path: name)
      guard manager.fileExists(atPath: url.path) else { continue }
      var values = URLResourceValues()
      values.isHidden = false
      try url.setResourceValues(values)
    }
  }

  private func deleteArchiveFolder(relative: String, clearPointer: Bool) async throws {
    guard Self.isSafeMeetingPath(relative) else {
      throw NSError(
        domain: "RemoteSync", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Meeting folder path is invalid"])
    }
    let config = try validatedRemoteConfiguration()
    let empty = FileManager.default.temporaryDirectory.appending(
      path: "MeetingNotesDelete-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    let archive = try localArchiveURL(for: config)
    let target = archive.appending(path: relative, directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: target.path) {
      try await run(
        "/usr/bin/rsync", ["-az", "--delete", empty.path + "/", target.path + "/"])
      try FileManager.default.removeItem(at: target)
    }
    if clearPointer {
      try? FileManager.default.removeItem(at: archive.appending(path: "current.json"))
    }

    if config.remoteSyncEnabled {
      let remoteFolder = "\(config.path)/\(relative)/"
      try await run(
        "/usr/bin/rsync",
        [
          "-az", "--delete", "-e", strictSSHCommand, empty.path + "/",
          "\(config.host):\(remoteFolder)",
        ])
      try await run(
        "/usr/bin/ssh",
        strictSSHArguments(host: config.host) + ["rmdir", remoteFolder])
      if clearPointer {
        try await run(
          "/usr/bin/ssh",
          strictSSHArguments(host: config.host) + ["rm", "-f", "\(config.path)/current.json"])
      }
    }
  }

  private func strictSSHArguments(host: String) -> [String] {
    [
      "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
      host,
    ]
  }

  private var strictSSHCommand: String {
    "/usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5"
  }

  private func localArchiveURL(for configuration: Configuration) throws -> URL {
    let path = (configuration.localPath as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    guard url.path != "/" else {
      throw NSError(
        domain: "ArchiveSync", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "The filesystem root cannot be used as the archive"])
    }
    return url
  }

  private func run(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      let errorPipe = Pipe()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      if let environment { process.environment = environment }
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errorPipe
      // Drain stderr while the process runs; waiting until termination can
      // deadlock once the child fills the 64KB pipe buffer.
      let drained = DrainedData()
      errorPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
        } else {
          drained.append(chunk)
        }
      }
      process.terminationHandler = { process in
        errorPipe.fileHandleForReading.readabilityHandler = nil
        // Collect any remainder that arrived between the last callback and exit.
        if let rest = try? errorPipe.fileHandleForReading.readToEnd() {
          drained.append(rest)
        }
        let data = drained.value
        if process.terminationStatus == 0 {
          continuation.resume()
        } else {
          let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
          continuation.resume(
            throwing: NSError(
              domain: "RemoteSync", code: Int(process.terminationStatus),
              userInfo: [
                NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "Remote sync failed"
              ]
            ))
        }
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }
}

/// Accumulates pipe output across the readability handler's callback queue and
/// the termination handler without data races.
private final class DrainedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ chunk: Data) {
    lock.lock()
    data.append(chunk)
    lock.unlock()
  }

  var value: Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

extension JSONDecoder {
  fileprivate static var meetingDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
