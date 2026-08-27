@preconcurrency import EventKit
import Foundation

@MainActor
final class CalendarService {
  private let store = EKEventStore()

  struct Suggestion: Sendable {
    let title: String
    let metadata: CalendarMetadata
  }

  /// Identifies the event backing a meeting that just stopped, so background
  /// refreshes do not immediately re-suggest it.
  struct Exclusion: Sendable, Equatable {
    let eventIdentifier: String?
    let title: String
  }

  /// Explicitly requests calendar access. Call from a user-initiated UI path
  /// (for example a Settings button or first-run flow), never implicitly.
  @discardableResult
  func requestAccess() async -> Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .fullAccess:
      return true
    case .notDetermined:
      return (try? await store.requestFullAccessToEvents()) ?? false
    default:
      return false
    }
  }

  func currentMeeting(excluding exclusion: Exclusion? = nil) async -> Suggestion? {
    // This read path runs from background refreshes; it must never trigger the
    // system permission prompt. The UI calls requestAccess() explicitly.
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
    let now = Date()
    let predicate = store.predicateForEvents(
      withStart: now.addingTimeInterval(-30 * 60),
      end: now.addingTimeInterval(30 * 60), calendars: nil
    )
    let candidates = store.events(matching: predicate)
      .filter { !$0.isAllDay && $0.endDate >= now.addingTimeInterval(-5 * 60) }
      .filter { !Self.shouldIgnore(title: $0.title, ignoredWords: IgnoredMeetingTitlesStore.load()) }
      .filter { !Self.isExcluded($0, by: exclusion) }
      .sorted {
        abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now))
      }
    guard let event = candidates.first else { return nil }
    let participants = (event.attendees ?? []).map(Self.participant)
    let metadata = CalendarMetadata(
      eventIdentifier: event.eventIdentifier,
      calendarTitle: event.calendar.title,
      scheduledStart: event.startDate,
      scheduledEnd: event.endDate,
      organizer: event.organizer.map(Self.participant),
      participants: participants,
      location: event.location,
      meetingURL: event.url
    )
    return Suggestion(title: event.title ?? "Meeting", metadata: metadata)
  }

  /// The event that backed a just-stopped meeting must not resurface as the
  /// next suggestion. Match on the identifier when one was captured; fall
  /// back to the title for meetings that never had calendar metadata.
  nonisolated private static func isExcluded(_ event: EKEvent, by exclusion: Exclusion?) -> Bool {
    guard let exclusion else { return false }
    if let identifier = exclusion.eventIdentifier {
      return event.eventIdentifier == identifier
    }
    return event.title == exclusion.title
  }

  nonisolated static func shouldIgnore(
    title: String?,
    ignoredWords: [String] = IgnoredMeetingTitlesStore.defaults
  ) -> Bool {
    guard let title else { return false }
    let words = title.localizedLowercase.split { !$0.isLetter && !$0.isNumber }
    let lowered = Set(words.map(String.init))
    return ignoredWords.contains { !$0.isEmpty && lowered.contains($0.localizedLowercase) }
  }

  private static func participant(_ participant: EKParticipant) -> MeetingParticipant {
    let email: String?
    if participant.url.scheme?.lowercased() == "mailto" {
      email =
        participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        .removingPercentEncoding
    } else {
      email = nil
    }
    let role: String? =
      switch participant.participantRole {
      case .chair: "chair"
      case .required: "required"
      case .optional: "optional"
      case .nonParticipant: "non-participant"
      default: nil
      }
    return MeetingParticipant(
      name: participant.name ?? email ?? "Unknown participant", email: email, role: role)
  }
}
