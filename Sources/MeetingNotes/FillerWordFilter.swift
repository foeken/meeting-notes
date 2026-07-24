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
  // The filter is language-blind, so ambiguous tokens must stay out of the
  // removal set. "er" is a common Dutch word ("er is", "hij is er") and "mm"
  // is frequently a short assent rather than a disfluency; only clearly
  // meaningless variants ("err", "mmm") remain removable.
  private static let words: Set<String> = [
    "ah", "ahh", "err", "hm", "hmm", "mmm", "uh", "uhh", "uhm", "um", "umm",
  ]

  private static let phrases = [
    #"(?i)(?<![\p{L}\p{N}])you\s+know\s*,"#,
    #"(?i)(?<![\p{L}\p{N}])i\s+mean\s*,"#,
  ]

  private static let startsWithFiller =
    #"(?i)^\s*(?:(?:uh+m*|um+|err+|h+m+|mmm+|ah+)\b[\p{P}\s]*|(?:you\s+know|i\s+mean)\s*,)"#

  static func apply(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = text
    let capitalizeAfterRemoval = text.range(of: startsWithFiller, options: .regularExpression) != nil
    result = result.replacingOccurrences(
      of: #"(?i),\s*(?:uh+m*|um+|err+|h+m+|mmm+|ah+)\b[,.]?\s*"#,
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
