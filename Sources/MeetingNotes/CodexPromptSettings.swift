import Foundation

enum CodexPromptSettingsStore {
  private static let key = "codexMeetingPromptTemplate"
  private static let summaryMessageKey = "codexSummaryMessageTemplate"
  private static let summaryMessageEnabledKey = "codexSummaryMessageEnabled"
  private static let autoCreateThreadsKey = "codexAutoCreateThreads"
  private static let modelKey = "codexTaskModel"
  private static let reasoningEffortKey = "codexTaskReasoningEffort"

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
    defaults.string(forKey: summaryMessageKey)
      ?? CodexThreadService.defaultSummaryMessageTemplate
  }

  static func saveSummaryMessage(_ template: String, to defaults: UserDefaults = .standard) {
    defaults.set(template, forKey: summaryMessageKey)
  }

  static func restoreDefaultSummaryMessage(to defaults: UserDefaults = .standard) -> String {
    defaults.removeObject(forKey: summaryMessageKey)
    return CodexThreadService.defaultSummaryMessageTemplate
  }

  static func summaryMessageEnabled(from defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: summaryMessageEnabledKey) as? Bool ?? false
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

  /// An empty model means "let Codex decide", which matches the behaviour
  /// before the model could be chosen.
  static func loadModel(from defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: modelKey) ?? ""
  }

  static func saveModel(_ model: String, to defaults: UserDefaults = .standard) {
    defaults.set(model, forKey: modelKey)
  }

  static func loadReasoningEffort(from defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: reasoningEffortKey) ?? ""
  }

  static func saveReasoningEffort(_ effort: String, to defaults: UserDefaults = .standard) {
    defaults.set(effort, forKey: reasoningEffortKey)
  }
}
