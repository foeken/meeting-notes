import Foundation

extension RemoteSyncService.Configuration {
  enum HookLocation: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case local
    case remote

    var id: String { rawValue }
    var label: String {
      switch self {
      case .disabled: "Off"
      case .local: "This Mac"
      case .remote: "Remote server"
      }
    }
  }

  /// Which finished document an HTTP hook sends.
  enum HookPayload: String, CaseIterable, Identifiable, Sendable {
    case meetingNotes
    case transcript

    var id: String { rawValue }
    var label: String {
      switch self {
      case .meetingNotes: "Meeting notes"
      case .transcript: "Word-for-word transcript"
      }
    }

    var fileName: String {
      switch self {
      case .meetingNotes: "meeting.md"
      case .transcript: "transcript.md"
      }
    }
  }

  struct HTTPHookHeader: Equatable, Sendable {
    let name: String
    let value: String
  }

  /// Parses `Name: value` lines. Blank lines and `#` comments are ignored so a
  /// user can annotate their header list.
  static func parseHookHeaders(_ raw: String) -> [HTTPHookHeader] {
    raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
        let separator = trimmed.firstIndex(of: ":")
      else { return nil }
      let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !value.isEmpty else { return nil }
      return HTTPHookHeader(name: name, value: value)
    }
  }

  /// Validates the destination of an HTTP hook without revealing header values.
  static func httpHookURLError(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
      url.host?.isEmpty == false
    else { return "Enter a complete URL, for example https://example.com/hook." }
    guard scheme == "https" || scheme == "http" else {
      return "The URL must start with https:// or http://."
    }
    return nil
  }

  enum Destination: String, CaseIterable, Identifiable, Sendable {
    case remote
    case local

    var id: String { rawValue }
    var label: String { self == .remote ? "Remote server" : "This Mac" }
  }

  var validationError: String? {
    let local = (localPath as NSString).expandingTildeInPath
    guard !local.isEmpty, local.hasPrefix("/") else {
      return "Choose an absolute local archive directory."
    }
    guard URL(fileURLWithPath: local).standardizedFileURL.path != "/" else {
      return "The filesystem root cannot be used as the archive."
    }
    if remoteSyncEnabled {
      let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !host.isEmpty else { return "Enter an SSH host." }
      guard host.allSatisfy({ $0.isLetter || $0.isNumber || ".-_@".contains($0) }) else {
        return "The SSH host contains unsupported characters."
      }
      guard !path.isEmpty, !path.contains(".."),
        path.allSatisfy({ $0.isLetter || $0.isNumber || "/-_.~".contains($0) })
      else { return "Enter a safe absolute or ~/ remote path." }
    }
    let hook = postMeetingHookCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    if !hook.isEmpty, postMeetingHookLocation == .remote, !remoteSyncEnabled {
      return "Enable remote sync before running the hook on the remote server."
    }
    if let urlError = Self.httpHookURLError(httpHookURL) { return urlError }
    return nil
  }

  var destinationDescription: String {
    remoteSyncEnabled
      ? "local archive + \(host):\(path)"
      : (localPath as NSString).expandingTildeInPath
  }
}

enum ArchiveSettingsStore {
  private enum Key {
    static let destination = "archive.destination"
    static let remoteHost = "archive.remoteHost"
    static let remotePath = "archive.remotePath"
    static let localPath = "archive.localPath"
    static let remoteEnabled = "archive.remoteEnabled"
    static let postMeetingHookLocation = "archive.postMeetingHookLocation"
    static let postMeetingHookCommand = "archive.postMeetingHookCommand"
    static let httpHookURL = "archive.httpHookURL"
    static let httpHookHeaders = "archive.httpHookHeaders"
    static let httpHookPayload = "archive.httpHookPayload"
  }

  static func load(from defaults: UserDefaults = .standard) -> RemoteSyncService.Configuration {
    let fallback = RemoteSyncService.Configuration.defaults
    let legacyDestination = defaults.string(forKey: Key.destination)
      .flatMap(RemoteSyncService.Configuration.Destination.init(rawValue:)) ?? fallback.destination
    let remoteEnabled = (defaults.object(forKey: Key.remoteEnabled) as? Bool)
      ?? (legacyDestination == .remote)
    let storedLocalPath = defaults.string(forKey: Key.localPath)
    let localPath = storedLocalPath == "~/MeetingNotes" && remoteEnabled
      ? RemoteSyncService.Configuration.defaultLocalPath
      : (storedLocalPath ?? fallback.localPath)
    return RemoteSyncService.Configuration(
      destination: remoteEnabled ? .remote : .local,
      host: defaults.string(forKey: Key.remoteHost) ?? fallback.host,
      path: defaults.string(forKey: Key.remotePath) ?? fallback.path,
      localPath: localPath,
      enabled: true,
      includeAudio: AudioRetentionSettingsStore.load(from: defaults),
      postMeetingHookLocation: defaults.string(forKey: Key.postMeetingHookLocation)
        .flatMap(RemoteSyncService.Configuration.HookLocation.init(rawValue:)) ?? fallback.postMeetingHookLocation,
      postMeetingHookCommand: defaults.string(forKey: Key.postMeetingHookCommand)
        ?? fallback.postMeetingHookCommand,
      httpHookURL: defaults.string(forKey: Key.httpHookURL) ?? fallback.httpHookURL,
      httpHookHeaders: defaults.string(forKey: Key.httpHookHeaders) ?? fallback.httpHookHeaders,
      httpHookPayload: defaults.string(forKey: Key.httpHookPayload)
        .flatMap(RemoteSyncService.Configuration.HookPayload.init(rawValue:))
        ?? fallback.httpHookPayload
    )
  }

  static func save(
    _ configuration: RemoteSyncService.Configuration,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(configuration.destination.rawValue, forKey: Key.destination)
    defaults.set(configuration.remoteSyncEnabled, forKey: Key.remoteEnabled)
    defaults.set(configuration.host, forKey: Key.remoteHost)
    defaults.set(configuration.path, forKey: Key.remotePath)
    defaults.set(configuration.localPath, forKey: Key.localPath)
    defaults.set(configuration.postMeetingHookLocation.rawValue, forKey: Key.postMeetingHookLocation)
    defaults.set(configuration.postMeetingHookCommand, forKey: Key.postMeetingHookCommand)
    defaults.set(configuration.httpHookURL, forKey: Key.httpHookURL)
    defaults.set(configuration.httpHookHeaders, forKey: Key.httpHookHeaders)
    defaults.set(configuration.httpHookPayload.rawValue, forKey: Key.httpHookPayload)
  }

  static func saveStorage(
    _ configuration: RemoteSyncService.Configuration,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(configuration.destination.rawValue, forKey: Key.destination)
    defaults.set(configuration.remoteSyncEnabled, forKey: Key.remoteEnabled)
    defaults.set(configuration.host, forKey: Key.remoteHost)
    defaults.set(configuration.path, forKey: Key.remotePath)
    defaults.set(configuration.localPath, forKey: Key.localPath)
  }

  static func saveHook(
    location: RemoteSyncService.Configuration.HookLocation,
    command: String,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(location.rawValue, forKey: Key.postMeetingHookLocation)
    defaults.set(command, forKey: Key.postMeetingHookCommand)
  }

  static func saveHTTPHook(
    url: String,
    headers: String,
    payload: RemoteSyncService.Configuration.HookPayload,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(url, forKey: Key.httpHookURL)
    defaults.set(headers, forKey: Key.httpHookHeaders)
    defaults.set(payload.rawValue, forKey: Key.httpHookPayload)
  }
}
