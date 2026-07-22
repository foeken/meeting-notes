import Foundation

struct TranscriptTurn: Codable, Identifiable, Equatable, Sendable {
  enum Source: String, Codable, Sendable { case microphone, system }

  let id: UUID
  let start: TimeInterval
  var end: TimeInterval
  var speaker: String
  var text: String
  let source: Source

  init(
    id: UUID = UUID(), start: TimeInterval, end: TimeInterval, speaker: String, text: String,
    source: Source
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.speaker = speaker
    self.text = text
    self.source = source
  }
}

struct MeetingParticipant: Codable, Equatable, Sendable {
  var name: String
  var email: String?
  var role: String?
}

struct CalendarMetadata: Codable, Equatable, Sendable {
  var eventIdentifier: String
  var calendarTitle: String
  var scheduledStart: Date
  var scheduledEnd: Date
  var organizer: MeetingParticipant?
  var participants: [MeetingParticipant]
  var location: String?
  var meetingURL: URL?

}

struct EvidenceItem: Codable, Equatable, Sendable {
  var text: String
  var timestamp: TimeInterval
  var owner: String?
}

struct TopicInsight: Codable, Equatable, Sendable {
  var title: String
  var summary: String
  var start: TimeInterval
  var end: TimeInterval
}

struct MeetingInsights: Codable, Equatable, Sendable {
  var summary: String
  var topics: [TopicInsight]
  var decisions: [EvidenceItem]
  var actionItems: [EvidenceItem]
  var openQuestions: [EvidenceItem]
  var keyStatements: [EvidenceItem]
  var generatedAt: Date
  var generator: String
}

struct TodayMeetingSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let startedAt: Date
  let endedAt: Date?
  let summary: String?
}

struct MeetingDocument: Codable, Sendable {
  var id: UUID
  var title: String
  var startedAt: Date
  var endedAt: Date?
  var calendar: CalendarMetadata?
  var status: Status
  var transcript: [TranscriptTurn]
  var insights: MeetingInsights?
  var transcriptionVersion: Int
  var transcriptDeletedAt: Date?
  var codexThreadID: String?

  enum Status: String, Codable, Sendable { case recording, processing, complete, failed }

  init(
    id: UUID,
    title: String,
    startedAt: Date,
    endedAt: Date? = nil,
    calendar: CalendarMetadata? = nil,
    status: Status,
    transcript: [TranscriptTurn],
    insights: MeetingInsights? = nil,
    transcriptionVersion: Int = 1,
    transcriptDeletedAt: Date? = nil,
    codexThreadID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.calendar = calendar
    self.status = status
    self.transcript = transcript
    self.insights = insights
    self.transcriptionVersion = transcriptionVersion
    self.transcriptDeletedAt = transcriptDeletedAt
    self.codexThreadID = codexThreadID
  }

  var calendarEventIdentifier: String? { calendar?.eventIdentifier }
}

struct CurrentMeetingPointer: Codable, Sendable {
  var active: Bool
  var meetingID: UUID
  var title: String
  var relativeFolder: String
  var startedAt: Date
  var updatedAt: Date
  var captureState: String?
}

extension TimeInterval {
  var meetingTimestamp: String {
    let seconds = max(0, Int(self.rounded(.down)))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
  }
}

extension String {
  var filenameSafe: String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let folded = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let joined = folded.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined(
      separator: "-"
    ).lowercased()
    return joined.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
  }
}
