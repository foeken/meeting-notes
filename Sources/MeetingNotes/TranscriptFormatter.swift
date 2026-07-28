import Foundation

/// Rebuilds readable transcript lines from the raw ASR fragment stream.
///
/// The streaming recognizer emits one turn per audio chunk (~1.12s), and it
/// cuts wherever the chunk ends — frequently in the middle of a word, with the
/// space at the seam lost ("gekre" + "gen"). Rendering those fragments one per
/// line produces an unreadable transcript, so this type merges neighbouring
/// fragments back into short timestamped lines.
///
/// This only affects rendering. The per-fragment turns stay in `meeting.json`,
/// so nothing is lost and the change is reversible.
enum TranscriptFormatter {
  /// Fragments are grouped into lines spanning at most this many seconds.
  /// Short lines keep timestamps precise enough to answer time-scoped
  /// questions ("what was said in the last five minutes") while still reading
  /// as sentences rather than as one-word stutters.
  static let mergeWindow: TimeInterval = 5

  /// A line may run past `mergeWindow` to reach the end of a sentence, but
  /// never past this. Microphone and system audio are merged as separate
  /// streams, so an over-long line from one stream would swallow the period
  /// its counterpart speaks in and make timestamps appear to jump backwards.
  static let maximumLineSpan: TimeInterval = 10

  /// The literal speaker recorded for every turn now that speaker labelling is
  /// gone. It carries no information, so it is not rendered.
  static let placeholderSpeaker = "Unknown"

  struct Line: Equatable, Sendable {
    let start: TimeInterval
    let speaker: String
    let text: String
  }

  static func isPlaceholderSpeaker(_ speaker: String) -> Bool {
    let trimmed = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
      || trimmed.caseInsensitiveCompare(placeholderSpeaker) == .orderedSame
  }

  /// Merges fragments into readable lines, keeping every fragment's text.
  ///
  /// Fragments are merged only within one (speaker, source) stream, so a
  /// microphone interjection can never be spliced into the middle of a word
  /// coming from system audio.
  static func mergedLines(
    _ turns: [TranscriptTurn], window: TimeInterval = mergeWindow
  ) -> [Line] {
    let cleaned =
      turns
      .map { (turn: $0, text: cleanFragment($0.text)) }
      .filter { !$0.text.isEmpty }
    guard !cleaned.isEmpty else { return [] }

    let vocabulary = interiorVocabulary(cleaned.map(\.text))
    var streams: [String: [(turn: TranscriptTurn, text: String)]] = [:]
    for entry in cleaned {
      streams["\(entry.turn.source.rawValue)\u{1}\(entry.turn.speaker)", default: []].append(entry)
    }

    var lines: [Line] = []
    for key in streams.keys.sorted() {
      let stream = streams[key]!.sorted { $0.turn.start < $1.turn.start }
      var start: TimeInterval?
      var speaker = ""
      var text = ""
      for entry in stream {
        guard let currentStart = start else {
          start = entry.turn.start
          speaker = entry.turn.speaker
          text = entry.text
          continue
        }
        let tight = joinsWithoutSpace(text, entry.text, vocabulary: vocabulary)
        // A line may only end at a real word boundary; closing it mid-word
        // would recreate exactly the split this merge exists to repair.
        // Past the window it also waits for the end of a sentence, so a line
        // rarely stops halfway through a thought ("Ik heb een" / "jaar.").
        let elapsed = entry.turn.start - currentStart
        let closes =
          !tight
          && elapsed >= window
          && (endsSentence(text) || elapsed >= maximumLineSpan)
        if closes {
          lines.append(Line(start: currentStart, speaker: speaker, text: tidy(text)))
          start = entry.turn.start
          speaker = entry.turn.speaker
          text = entry.text
        } else {
          text += (tight ? "" : " ") + entry.text
        }
      }
      if let currentStart = start {
        lines.append(Line(start: currentStart, speaker: speaker, text: tidy(text)))
      }
    }

    return
      lines
      .filter { !$0.text.isEmpty }
      .enumerated()
      .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
      .map(\.element)
  }

  /// Renders merged lines as Markdown, always keeping the timestamp so content
  /// stays locatable by time.
  static func markdown(_ turns: [TranscriptTurn], window: TimeInterval = mergeWindow) -> String {
    let rendered = mergedLines(turns, window: window).map(markdownLine)
    return rendered.isEmpty ? "" : rendered.joined(separator: "\n\n") + "\n\n"
  }

  static func markdownLine(_ line: Line) -> String {
    isPlaceholderSpeaker(line.speaker)
      ? "**[\(line.start.meetingTimestamp)]** \(line.text)"
      : "**[\(line.start.meetingTimestamp)] \(line.speaker):** \(line.text)"
  }

  /// Plain-text lines for the enrichment prompt. Timestamps are kept so the
  /// model can answer time-scoped questions and cite accurate times.
  static func promptLines(_ turns: [TranscriptTurn], window: TimeInterval = mergeWindow)
    -> [String]
  {
    mergedLines(turns, window: window).map { line in
      isPlaceholderSpeaker(line.speaker)
        ? "[\(line.start.meetingTimestamp)] \(line.text)"
        : "[\(line.start.meetingTimestamp)] \(line.speaker): \(line.text)"
    }
  }

  // MARK: - Text repair

  /// Removes the recognizer's unknown-token marker and normalizes whitespace.
  static func cleanFragment(_ text: String) -> String {
    text
      .replacingOccurrences(of: "<unk>", with: " ")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func tidy(_ text: String) -> String {
    var result = text.replacingOccurrences(
      of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"\s{2,}"#, with: " ", options: .regularExpression)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// True when the text already closes a sentence, which is the natural place
  /// to end a rendered line.
  private static func endsSentence(_ text: String) -> Bool {
    guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
      return false
    }
    return ".!?".contains(last)
  }

  /// Words that appear in the interior of a fragment are surrounded by spaces
  /// the recognizer itself produced, so they are known-complete words. That
  /// makes the meeting its own dictionary, which works for any language
  /// without shipping word lists.
  private static func interiorVocabulary(_ texts: [String]) -> Set<String> {
    var vocabulary: Set<String> = []
    for text in texts {
      let tokens = text.split(separator: " ")
      guard tokens.count > 2 else { continue }
      for token in tokens.dropFirst().dropLast() {
        let word = normalized(String(token))
        if word.count > 1 { vocabulary.insert(word) }
      }
    }
    return vocabulary
  }

  private static func normalized(_ token: String) -> String {
    String(token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" })
  }

  /// Decides whether two fragments are two halves of one word (join tightly)
  /// or two separate words (join with a space).
  private static func joinsWithoutSpace(
    _ previous: String, _ next: String, vocabulary: Set<String>
  ) -> Bool {
    guard let lastCharacter = previous.last, let firstCharacter = next.first else { return false }
    // Trailing punctuation belongs to the word it follows: ". Die waren" must
    // not start a line with a stray period.
    if !firstCharacter.isLetter && !firstCharacter.isNumber { return true }
    // The recognizer already closed the sentence, so this is a new word.
    if ".,!?;:".contains(lastCharacter) { return false }
    // Word halves are not re-capitalized mid-word, so an uppercase start marks
    // a new sentence or a proper noun.
    if firstCharacter.isUppercase { return false }

    let last = normalized(String(previous.split(separator: " ").last ?? ""))
    let first = normalized(String(next.split(separator: " ").first ?? ""))
    guard !last.isEmpty, !first.isEmpty else { return false }
    // Both halves are complete words elsewhere in this meeting.
    if vocabulary.contains(last) && vocabulary.contains(first) { return false }
    // Their concatenation is a word this meeting used elsewhere.
    if vocabulary.contains(last + first) { return true }
    // A short unrecognized stub at either side of the seam is far more likely
    // to be half a word than a real word.
    if last.count <= 3 && !vocabulary.contains(last) { return true }
    if first.count <= 3 && !vocabulary.contains(first) { return true }
    return false
  }
}
