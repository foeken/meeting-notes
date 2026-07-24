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
        ?? fallback.postMeetingHookCommand
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
}
