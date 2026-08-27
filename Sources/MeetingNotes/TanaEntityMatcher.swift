import Foundation

enum TanaEntityMatcher {
  private struct Match {
    let name: String
    let score: Double
    let fuzzyEvidence: String?
  }

  static func relevantNames(
    from entityNames: [String], meeting: MeetingDocument, limit: Int = 200
  ) -> [String] {
    let organizerName: [String] = [meeting.calendar?.organizer?.name].compactMap { $0 }
    let participantNames: [String] = meeting.calendar?.participants.map(\.name) ?? []
    let speakerNames: [String] = meeting.transcript.map(\.speaker)
    let transcriptTexts: [String] = meeting.transcript.map(\.text)
    let sourceWordsList: [String] =
      [meeting.title] + organizerName + participantNames + speakerNames + transcriptTexts
    let source = sourceWordsList.joined(separator: " ")
    let sourceWords = normalize(source).split(separator: " ").map(String.init)
    let spokenWords = Set(sourceWords.filter { $0.count >= 4 })
    guard !spokenWords.isEmpty else { return [] }

    let matches: [Match] = entityNames.compactMap { rawName in
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalizedName = normalize(name)
      guard !normalizedName.isEmpty else { return nil }
      let nameWords = normalizedName.split(separator: " ").map(String.init)
      guard !nameWords.isEmpty else { return nil }

      // Exact matching is token based so a short entity such as "Mark" does not match
      // an unrelated word such as "market".
      if containsSubsequence(sourceWords, nameWords) { return Match(name: name, score: 0, fuzzyEvidence: nil) }

      if nameWords.count == 1, let evidence = closestWord(to: nameWords[0], in: spokenWords),
         evidence.score <= 0.30
      {
        return Match(name: name, score: evidence.score, fuzzyEvidence: evidence.word)
      }

      // A full Tana name may only be suggested when the transcript supports both
      // its given name and its family name. A bare first name must never expand to
      // a specific person. Particles (van, ten, de, …) are not identity evidence.
      let significant = nameWords.filter { !nameParticles.contains($0) && $0.count >= 3 }
      guard significant.count >= 2, let familyName = significant.last,
            spokenWords.contains(familyName), let givenName = significant.first,
            let givenEvidence = closestWord(to: givenName, in: spokenWords),
            givenEvidence.score <= 0.20
      else { return nil }
      return Match(name: name, score: givenEvidence.score, fuzzyEvidence: nil)
    }

    // A fuzzy source token that plausibly maps to more than one Tana entity is
    // ambiguous. Suppress all such candidates rather than choosing a person.
    let ambiguousEvidence = Dictionary(grouping: matches.compactMap { match in
      match.fuzzyEvidence.map { ($0, match.name) }
    }, by: \.0)
      .filter { Set($0.value.map { $0.1.lowercased() }).count > 1 }
      .keys

    return matches.filter { match in
      guard let evidence = match.fuzzyEvidence else { return true }
      return !ambiguousEvidence.contains(evidence)
    }.sorted {
      if $0.score != $1.score { return $0.score < $1.score }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    .prefix(limit)
    .map(\.name)
  }

  private static let nameParticles: Set<String> = [
    "da", "de", "den", "der", "di", "la", "ten", "ter", "van", "von",
  ]

  private static func containsSubsequence(_ source: [String], _ candidate: [String]) -> Bool {
    guard candidate.count <= source.count else { return false }
    return source.indices.contains { start in
      guard source.distance(from: start, to: source.endIndex) >= candidate.count else { return false }
      return Array(source[start..<source.index(start, offsetBy: candidate.count)]) == candidate
    }
  }

  private static func closestWord(to expected: String, in spokenWords: Set<String>)
    -> (word: String, score: Double)?
  {
    spokenWords.compactMap { spoken -> (String, Double)? in
      guard abs(expected.count - spoken.count) <= 2 else { return nil }
      let distance = editDistance(expected, spoken)
      return (spoken, Double(distance) / Double(max(expected.count, spoken.count)))
    }.min { $0.1 < $1.1 }
  }

  private static func normalize(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
      .reduce(into: "") { $0.append($1) }
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }

  private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
    let left = Array(lhs)
    let right = Array(rhs)
    var previous = Array(0...right.count)
    for (leftIndex, leftCharacter) in left.enumerated() {
      var current = [leftIndex + 1]
      current.reserveCapacity(right.count + 1)
      for (rightIndex, rightCharacter) in right.enumerated() {
        current.append(min(
          current[rightIndex] + 1,
          previous[rightIndex + 1] + 1,
          previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
        ))
      }
      previous = current
    }
    return previous[right.count]
  }
}
