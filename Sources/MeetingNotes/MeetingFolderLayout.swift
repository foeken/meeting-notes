import Foundation

/// Where a meeting folder lives inside the private spool and the archive.
///
/// Meetings are grouped by ISO week so the tree reads like a calendar:
/// `2026/W31/2026-07-28/1030-project-review-a1b2c3d4`.
///
/// The original `2026/07/28/…` layout stays valid everywhere. An archive
/// written before this change keeps that shape until it is migrated, and a
/// remote archive can lag behind the local one, so both must be recognised.
enum MeetingFolderLayout {
  /// Both layouts are `<a>/<b>/<c>/<meeting>`, so a meeting path is always
  /// four components deep. Sync, delete, and hook paths rely on that.
  static let componentCount = 4

  static let isoCalendar: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }()

  /// The `year/week/date` prefix a meeting starting at `date` belongs to.
  /// The year is the ISO week-numbering year, so the last days of December
  /// stay with the week they actually belong to instead of splitting it.
  static func dayPath(for date: Date, calendar: Calendar = isoCalendar) -> String {
    let parts = calendar.dateComponents(
      [.yearForWeekOfYear, .weekOfYear, .year, .month, .day], from: date)
    guard let weekYear = parts.yearForWeekOfYear, let week = parts.weekOfYear,
      let year = parts.year, let month = parts.month, let day = parts.day
    else { return "" }
    return String(format: "%04d/W%02d/%04d-%02d-%02d", weekYear, week, year, month, day)
  }

  /// Rewrites a legacy `2026/07/28/<meeting>` path into the week layout,
  /// keeping the original date so nothing is regrouped by accident. Returns
  /// `nil` for anything already migrated or otherwise unrecognised.
  static func migratedPath(
    forLegacy relativePath: String, calendar: Calendar = isoCalendar
  ) -> String? {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == componentCount,
      isLegacyDayPath(Array(components.prefix(3))),
      let year = Int(components[0]), let month = Int(components[1]),
      let day = Int(components[2])
    else { return nil }
    // Midday keeps the date stable across daylight-saving transitions.
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = 12
    guard let date = calendar.date(from: parts) else { return nil }
    return dayPath(for: date, calendar: calendar) + "/" + components[3]
  }

  /// `2026/07/28`
  static func isLegacyDayPath(_ components: [Substring]) -> Bool {
    components.count == 3
      && components[0].count == 4 && components[0].allSatisfy(\.isNumber)
      && components[1].count == 2 && components[1].allSatisfy(\.isNumber)
      && components[2].count == 2 && components[2].allSatisfy(\.isNumber)
  }

  /// `2026/W31/2026-07-28`
  static func isWeekDayPath(_ components: [Substring]) -> Bool {
    guard components.count == 3,
      components[0].count == 4, components[0].allSatisfy(\.isNumber),
      components[1].count == 3, components[1].first == "W",
      components[1].dropFirst().allSatisfy(\.isNumber)
    else { return false }
    let date = components[2].split(separator: "-", omittingEmptySubsequences: false)
    return date.count == 3
      && date[0].count == 4 && date[1].count == 2 && date[2].count == 2
      && date.allSatisfy { $0.allSatisfy(\.isNumber) }
  }
}
