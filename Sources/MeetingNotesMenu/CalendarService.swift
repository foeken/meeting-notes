import EventKit
import Foundation

@MainActor
final class CalendarService {
  private let store = EKEventStore()

  struct Suggestion: Sendable {
    let title: String
    let metadata: CalendarMetadata
  }

  func currentMeeting() async -> Suggestion? {
    do {
      let status = EKEventStore.authorizationStatus(for: .event)
      if status == .notDetermined {
        guard try await store.requestFullAccessToEvents() else { return nil }
      } else if status != .fullAccess {
        return nil
      }

      let now = Date()
      let predicate = store.predicateForEvents(
        withStart: now.addingTimeInterval(-30 * 60),
        end: now.addingTimeInterval(30 * 60), calendars: nil
      )
      let candidates = store.events(matching: predicate)
        .filter { !$0.isAllDay && $0.endDate >= now.addingTimeInterval(-5 * 60) }
        .filter { !Self.shouldIgnore(title: $0.title) }
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
    } catch { return nil }
  }

  nonisolated static func shouldIgnore(title: String?) -> Bool {
    guard let title else { return false }
    let words = title.localizedLowercase.split { !$0.isLetter && !$0.isNumber }
    return words.contains("block") || words.contains("focus")
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
