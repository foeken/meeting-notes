import Foundation

@MainActor
final class MeetingAutoStopScheduler {
  static let defaultGracePeriod: Duration = .seconds(15)

  private var pendingStop: Task<Void, Never>?

  func update(
    recordingMeetingApp: String?,
    detectedMeetingApp: String?,
    isCapturing: Bool,
    gracePeriod: Duration = defaultGracePeriod,
    stop: @escaping @MainActor @Sendable () async -> Void
  ) {
    pendingStop?.cancel()
    pendingStop = nil
    guard recordingMeetingApp != nil, detectedMeetingApp == nil, isCapturing else { return }
    pendingStop = Task { @MainActor [weak self] in
      try? await Task.sleep(for: gracePeriod)
      guard !Task.isCancelled else { return }
      // The stop callback enters the normal recording shutdown path, which calls
      // `cancel()` to invalidate any pending automatic stop. Clear this handle
      // first so that shutdown does not cancel the task currently running it.
      self?.pendingStop = nil
      await stop()
    }
  }

  func cancel() {
    pendingStop?.cancel()
    pendingStop = nil
  }
}
