import Foundation

struct VocabularyEntry: Identifiable, Equatable, Sendable {
  var id: String { term.lowercased() }
  let term: String
  let aliases: [String]
}

enum VocabularySettingsStore {
  private static let key = "recognition.customVocabulary"
  static let maximumEntries = 256

  private static func loadDraft(from defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: key) ?? ""
  }

  static func load(from defaults: UserDefaults = .standard) -> [VocabularyEntry] {
    parse(loadDraft(from: defaults))
  }

  static func save(_ entries: [VocabularyEntry], to defaults: UserDefaults = .standard) {
    defaults.set(formatted(entries), forKey: key)
  }

  static func parse(_ draft: String) -> [VocabularyEntry] {
    var seen = Set<String>()
    return draft.components(separatedBy: .newlines).compactMap { line in
      let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      let term = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
      let aliases = parts.count == 2
        ? parts[1].split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }
        : []
      return VocabularyEntry(term: term, aliases: Array(Set(aliases.map { $0.lowercased() })).sorted())
    }
  }

  static func formatted(_ entries: [VocabularyEntry]) -> String {
    entries.prefix(maximumEntries).map { entry in
      entry.aliases.isEmpty ? entry.term : "\(entry.term) | \(entry.aliases.joined(separator: ", "))"
    }.joined(separator: "\n")
  }
}
