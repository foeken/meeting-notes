import Foundation

enum AudioRetentionSettingsStore {
  private static let key = "recording.keepAudioAfterProcessing"

  static func load(from defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  static func save(_ keepAudio: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(keepAudio, forKey: key)
  }
}
