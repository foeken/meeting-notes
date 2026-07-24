import Foundation

/// Prevents idle system sleep while audio capture is actively running.
/// Explicit sleep and closing the lid still take precedence.
final class RecordingWakeLock: @unchecked Sendable {
  private let lock = NSLock()
  private var activity: NSObjectProtocol?

  var isHeld: Bool {
    lock.withLock { activity != nil }
  }

  func acquire() {
    lock.withLock {
      guard activity == nil else { return }
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Recording a meeting")
    }
  }

  func release() {
    lock.withLock {
      guard let activity else { return }
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
  }

  deinit {
    release()
  }
}
