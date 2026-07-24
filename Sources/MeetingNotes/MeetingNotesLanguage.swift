import Foundation

enum MeetingNotesLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
  case source
  case arabic
  case chineseSimplified
  case danish
  case dutch
  case english
  case finnish
  case french
  case german
  case italian
  case japanese
  case korean
  case norwegian
  case polish
  case portuguese
  case spanish
  case swedish
  case turkish
  case ukrainian

  var id: Self { self }

  var label: String {
    switch self {
    case .source: "Same as transcript"
    case .arabic: "Arabic"
    case .chineseSimplified: "Chinese (Simplified)"
    case .danish: "Danish"
    case .dutch: "Dutch"
    case .english: "English"
    case .finnish: "Finnish"
    case .french: "French"
    case .german: "German"
    case .italian: "Italian"
    case .japanese: "Japanese"
    case .korean: "Korean"
    case .norwegian: "Norwegian"
    case .polish: "Polish"
    case .portuguese: "Portuguese"
    case .spanish: "Spanish"
    case .swedish: "Swedish"
    case .turkish: "Turkish"
    case .ukrainian: "Ukrainian"
    }
  }

  var processingInstruction: String {
    switch self {
    case .source:
      "Write every generated text field in the predominant language of the transcript."
    default:
      "Write every generated text field in \(label), regardless of the transcript language."
    }
  }
}

enum MeetingNotesLanguageStore {
  private static let key = "meetingNotesLanguage"

  static func load(from defaults: UserDefaults = .standard) -> MeetingNotesLanguage {
    guard let rawValue = defaults.string(forKey: key) else { return .source }
    return MeetingNotesLanguage(rawValue: rawValue) ?? .source
  }

  static func save(
    _ language: MeetingNotesLanguage,
    to defaults: UserDefaults = .standard
  ) {
    defaults.set(language.rawValue, forKey: key)
  }
}
