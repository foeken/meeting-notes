import Foundation

/// The customizable part of the summary prompt: the instructions describing
/// what the meeting notes should contain and how they should read. The
/// structural rules (schema, no invented facts, neutral attribution) stay in
/// code, so a custom prompt can change tone and emphasis without being able
/// to break the output contract.
enum SummarySettingsStore {
  private static let guidanceKey = "summary.guidance"

  static func loadGuidance(from defaults: UserDefaults = .standard) -> String {
    guard let stored = defaults.string(forKey: guidanceKey),
      !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return OpenAIEnricher.defaultSummaryGuidance }
    return stored
  }

  static func saveGuidance(_ guidance: String, to defaults: UserDefaults = .standard) {
    defaults.set(guidance, forKey: guidanceKey)
  }

  @discardableResult
  static func restoreDefaultGuidance(in defaults: UserDefaults = .standard) -> String {
    defaults.removeObject(forKey: guidanceKey)
    return OpenAIEnricher.defaultSummaryGuidance
  }
}
