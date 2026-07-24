import Foundation

enum FillerWordSettingsStore {
  private static let key = "removeFillerWords"

  static func load(from defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
  }

  static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: key)
  }
}

enum FillerWordFilter {
  private static let words: Set<String> = [
    "ah", "ahh", "er", "err", "hm", "hmm", "mm", "mmm", "uh", "uhh", "um", "umm",
  ]

  private static let phrases = [
    #"(?i)(?<![\p{L}\p{N}])you\s+know\s*,"#,
    #"(?i)(?<![\p{L}\p{N}])i\s+mean\s*,"#,
  ]

  private static let startsWithFiller =
    #"(?i)^\s*(?:(?:uh+|um+|er+|h+m+|mm+|ah+)\b[\p{P}\s]*|(?:you\s+know|i\s+mean)\s*,)"#

  static func apply(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = text
    let capitalizeAfterRemoval = text.range(of: startsWithFiller, options: .regularExpression) != nil
    result = result.replacingOccurrences(
      of: #"(?i),\s*(?:uh+|um+|er+|h+m+|mm+|ah+)\b[,.]?\s*"#,
      with: " ", options: .regularExpression)
    for pattern in phrases {
      result = result.replacingOccurrences(
        of: pattern, with: "", options: .regularExpression)
    }

    result = result.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
      let normalized = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
      return words.contains(normalized) ? nil : String(token)
    }.joined(separator: " ")

    result = result.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
    result = result.replacingOccurrences(of: #"([,;:]){2,}"#, with: "$1", options: .regularExpression)
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard capitalizeAfterRemoval,
      let firstLetter = result.firstIndex(where: \.isLetter), result[firstLetter].isLowercase
    else { return result }
    result.replaceSubrange(firstLetter...firstLetter, with: result[firstLetter].uppercased())
    return result
  }

  static func apply(to turns: [TranscriptTurn]) -> [TranscriptTurn] {
    guard FillerWordSettingsStore.load() else { return turns }
    return turns.compactMap { turn in
      var cleaned = turn
      cleaned.text = apply(turn.text)
      return cleaned.text.isEmpty ? nil : cleaned
    }
  }
}
