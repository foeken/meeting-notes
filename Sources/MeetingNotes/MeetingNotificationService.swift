import Foundation
import UserNotifications

@MainActor
final class MeetingNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  static let shared = MeetingNotificationService()

  var onStartRecording: (@MainActor @Sendable () -> Void)?
  var onDismiss: (@MainActor @Sendable () -> Void)?
  var onStopRecording: (@MainActor @Sendable () -> Void)?

  private let notificationIdentifier = "meeting-detected"
  private let categoryIdentifier = "meeting-detected-actions"
  private let startRecordingActionIdentifier = "start-recording"
  private let dismissActionIdentifier = "not-now"
  private let endedIdentifier = "meeting-ended"
  private let endedCategoryIdentifier = "meeting-ended-actions"
  private let stopRecordingActionIdentifier = "stop-recording"
  private let keepRecordingActionIdentifier = "keep-recording"
  private let center = UNUserNotificationCenter.current()
  private var notificationArmed = true
  private var rearmTask: Task<Void, Never>?

  private override init() {
    super.init()
    center.delegate = self
    let startRecording = UNNotificationAction(
      identifier: startRecordingActionIdentifier,
      title: "Start Recording")
    let dismiss = UNNotificationAction(
      identifier: dismissActionIdentifier,
      title: "Not Now")
    let stopRecording = UNNotificationAction(
      identifier: stopRecordingActionIdentifier,
      title: "Stop Recording")
    let keepRecording = UNNotificationAction(
      identifier: keepRecordingActionIdentifier,
      title: "Keep Recording")
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: categoryIdentifier,
        actions: [startRecording, dismiss],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: endedCategoryIdentifier,
        actions: [stopRecording, keepRecording],
        intentIdentifiers: []),
    ])
  }

  /// The video call ended while a manually started recording is still
  /// running: suggest stopping instead of stopping automatically.
  func suggestStopAfterMeetingEnded(app: String) {
    Task { @MainActor in
      do {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app) meeting ended"
        content.body = "Meeting Notes is still recording."
        content.sound = .default
        content.categoryIdentifier = endedCategoryIdentifier
        try await center.add(UNNotificationRequest(
          identifier: endedIdentifier, content: content, trigger: nil))
      } catch {
        // The menu bar still shows the recording state if notifications fail.
      }
    }
  }

  func clearStopSuggestion() {
    center.removeDeliveredNotifications(withIdentifiers: [endedIdentifier])
    center.removePendingNotificationRequests(withIdentifiers: [endedIdentifier])
  }

  func showDetectedMeeting(app: String) {
    if let rearmTask {
      // A pending re-arm means the previous meeting ended and the cooldown was
      // running. A new meeting cancels the cooldown but must still notify, so
      // treat the cancelled re-arm as if it had already fired.
      rearmTask.cancel()
      self.rearmTask = nil
      notificationArmed = true
    }
    guard notificationArmed else { return }
    notificationArmed = false

    Task { @MainActor in
      do {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(app) meeting detected"
        content.body = "Camera and microphone are active. Open Meeting Notes to start recording."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        let request = UNNotificationRequest(
          identifier: notificationIdentifier,
          content: content,
          trigger: nil)
        try await center.add(request)
      } catch {
        // Detection remains visible in the menu-bar UI if notifications are unavailable.
      }
    }
  }

  func meetingEnded() {
    clearDetectedMeeting()
    rearmTask?.cancel()
    rearmTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(60))
      guard !Task.isCancelled else { return }
      self?.notificationArmed = true
      self?.rearmTask = nil
    }
  }

  func suppressCurrentMeeting() {
    rearmTask?.cancel()
    rearmTask = nil
    notificationArmed = false
    clearDetectedMeeting()
  }

  private func clearDetectedMeeting() {
    center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
    center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionIdentifier = response.actionIdentifier
    completionHandler()
    Task { @MainActor [weak self] in
      guard let self else { return }
      switch actionIdentifier {
      case startRecordingActionIdentifier:
        onStartRecording?()
      case dismissActionIdentifier:
        onDismiss?()
      case stopRecordingActionIdentifier:
        onStopRecording?()
      case keepRecordingActionIdentifier:
        break
      default:
        break
      }
    }
  }
}
