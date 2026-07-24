import Foundation

enum CodexPromptSettingsStore {
  private static let key = "codexMeetingPromptTemplate"
  private static let summaryMessageKey = "codexSummaryMessageTemplate"
  private static let summaryMessageEnabledKey = "codexSummaryMessageEnabled"
  private static let autoCreateThreadsKey = "codexAutoCreateThreads"

  static func load(from defaults: UserDefaults = .standard) -> String {
    guard let stored = defaults.string(forKey: key),
      !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return CodexThreadService.defaultPromptTemplate }
    return stored
  }

  static func save(_ template: String, to defaults: UserDefaults = .standard) {
    defaults.set(template, forKey: key)
  }

  static func restoreDefault(to defaults: UserDefaults = .standard) -> String {
    defaults.removeObject(forKey: key)
    return CodexThreadService.defaultPromptTemplate
  }

  static func loadSummaryMessage(from defaults: UserDefaults = .standard) -> String {
    guard let stored = defaults.string(forKey: summaryMessageKey),
      !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return CodexThreadService.defaultSummaryMessageTemplate }
    return stored
  }

  static func saveSummaryMessage(_ template: String, to defaults: UserDefaults = .standard) {
    defaults.set(template, forKey: summaryMessageKey)
  }

  static func restoreDefaultSummaryMessage(to defaults: UserDefaults = .standard) -> String {
    defaults.removeObject(forKey: summaryMessageKey)
    return CodexThreadService.defaultSummaryMessageTemplate
  }

  static func summaryMessageEnabled(from defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: summaryMessageEnabledKey) as? Bool ?? true
  }

  static func saveSummaryMessageEnabled(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: summaryMessageEnabledKey)
  }

  static func autoCreateThreads(from defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: autoCreateThreadsKey) as? Bool ?? false
  }

  static func saveAutoCreateThreads(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: autoCreateThreadsKey)
  }
}
