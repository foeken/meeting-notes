import Foundation

enum CodexPromptSettingsStore {
  private static let key = "codexMeetingPromptTemplate"

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
}
