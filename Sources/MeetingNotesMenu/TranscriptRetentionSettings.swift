import Foundation

struct TranscriptRetentionSettings: Equatable, Sendable {
  static let defaultDays = 90

  var enabled: Bool
  var days: Int

  init(enabled: Bool = true, days: Int = defaultDays) {
    self.enabled = enabled
    self.days = Self.validatedDays(days)
  }

  static func validatedDays(_ days: Int) -> Int {
    min(max(days, 1), 3_650)
  }
}

enum TranscriptRetentionSettingsStore {
  private static let enabledKey = "retention.transcripts.enabled"
  private static let daysKey = "retention.transcripts.days"

  static func load(from defaults: UserDefaults = .standard) -> TranscriptRetentionSettings {
    let enabled = defaults.object(forKey: enabledKey) == nil
      ? true
      : defaults.bool(forKey: enabledKey)
    let storedDays = defaults.object(forKey: daysKey) == nil
      ? TranscriptRetentionSettings.defaultDays
      : defaults.integer(forKey: daysKey)
    return TranscriptRetentionSettings(enabled: enabled, days: storedDays)
  }

  static func save(
    _ settings: TranscriptRetentionSettings,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(settings.enabled, forKey: enabledKey)
    defaults.set(TranscriptRetentionSettings.validatedDays(settings.days), forKey: daysKey)
  }
}
