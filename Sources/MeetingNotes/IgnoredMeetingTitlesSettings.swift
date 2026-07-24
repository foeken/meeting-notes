import Foundation

enum IgnoredMeetingTitlesStore {
  private static let key = "ignoredMeetingTitleWords"
  static let defaults = ["Block", "Focus", "Lunch"]

  static func load(from userDefaults: UserDefaults = .standard) -> [String] {
    guard let stored = userDefaults.array(forKey: key) as? [String] else {
      return defaults
    }
    return stored
  }

  static func save(_ words: [String], to userDefaults: UserDefaults = .standard) {
    userDefaults.set(words, forKey: key)
  }

  static func parse(_ text: String) -> [String] {
    var seen = Set<String>()
    return text
      .split(whereSeparator: { $0 == "," || $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .filter { seen.insert($0.localizedLowercase).inserted }
  }
}
