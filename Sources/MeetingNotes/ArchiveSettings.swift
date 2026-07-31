import Foundation
import Security

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
    // Swift treats "\r\n" as one Character, so splitting on "\n" alone would
    // leave CRLF input as a single line; split on any newline instead.
    raw.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Legacy key, read once for migration; no longer written.
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
    let remoteEnabled = (defaults.object(forKey: Key.remoteEnabled) as? Bool)
      ?? (defaults.string(forKey: Key.destination) == "remote")
    let storedLocalPath = defaults.string(forKey: Key.localPath)
    let localPath = storedLocalPath == "~/MeetingNotes" && remoteEnabled
      ? RemoteSyncService.Configuration.defaultLocalPath
      : (storedLocalPath ?? fallback.localPath)
    return RemoteSyncService.Configuration(
      remoteSyncEnabled: remoteEnabled,
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
      httpHookHeaders: loadHTTPHookHeaders(from: defaults),
      httpHookPayload: defaults.string(forKey: Key.httpHookPayload)
        .flatMap(RemoteSyncService.Configuration.HookPayload.init(rawValue:))
        ?? fallback.httpHookPayload
    )
  }

  /// Headers commonly carry an Authorization bearer token, so they live in the
  /// Keychain rather than plaintext UserDefaults. A legacy plaintext value is
  /// migrated on first load, then removed from defaults. Test suites (any
  /// non-standard UserDefaults) keep the plaintext path so they stay hermetic.
  private static func loadHTTPHookHeaders(from defaults: UserDefaults) -> String {
    guard defaults === UserDefaults.standard else {
      return defaults.string(forKey: Key.httpHookHeaders) ?? ""
    }
    if let stored = defaults.string(forKey: Key.httpHookHeaders) {
      // Legacy plaintext value: move it into the Keychain once. Old seeded
      // example headers are dropped rather than migrated.
      let cleaned = stored.contains("sk-example-token") ? "" : stored
      if HookHeaderKeychainStore.save(cleaned) {
        defaults.removeObject(forKey: Key.httpHookHeaders)
      }
      return cleaned
    }
    return HookHeaderKeychainStore.load() ?? ""
  }

  private static func persistHTTPHookHeaders(_ headers: String, to defaults: UserDefaults) {
    if defaults === UserDefaults.standard, HookHeaderKeychainStore.save(headers) {
      defaults.removeObject(forKey: Key.httpHookHeaders)
    } else {
      // Keychain unavailable (or a test suite): plaintext keeps working so the
      // user's hook never silently loses its credentials.
      defaults.set(headers, forKey: Key.httpHookHeaders)
    }
  }

  static func save(
    _ configuration: RemoteSyncService.Configuration,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(configuration.remoteSyncEnabled, forKey: Key.remoteEnabled)
    defaults.set(configuration.host, forKey: Key.remoteHost)
    defaults.set(configuration.path, forKey: Key.remotePath)
    defaults.set(configuration.localPath, forKey: Key.localPath)
    defaults.set(configuration.postMeetingHookLocation.rawValue, forKey: Key.postMeetingHookLocation)
    defaults.set(configuration.postMeetingHookCommand, forKey: Key.postMeetingHookCommand)
    defaults.set(configuration.httpHookURL, forKey: Key.httpHookURL)
    persistHTTPHookHeaders(configuration.httpHookHeaders, to: defaults)
    defaults.set(configuration.httpHookPayload.rawValue, forKey: Key.httpHookPayload)
  }

  static func saveStorage(
    _ configuration: RemoteSyncService.Configuration,
    to defaults: UserDefaults = .standard
  ) {
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
    persistHTTPHookHeaders(headers, to: defaults)
    defaults.set(payload.rawValue, forKey: Key.httpHookPayload)
  }
}

/// Stores the HTTP hook header block as a generic Keychain password, mirroring
/// TanaOAuthService's token storage. The block frequently contains an
/// Authorization bearer token that must not sit in plaintext UserDefaults.
enum HookHeaderKeychainStore {
  static let service = "app.meetingnotes.menu.httphook"
  private static let account = "headers"

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  @discardableResult
  static func save(_ headers: String) -> Bool {
    let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
      return false
    }
    var item = baseQuery
    item[kSecValueData as String] = Data(headers.utf8)
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

  static func delete() {
    SecItemDelete(baseQuery as CFDictionary)
  }
}
