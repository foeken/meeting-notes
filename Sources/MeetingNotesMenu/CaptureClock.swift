import Foundation

/// A monotonic, pause-aware clock shared by every capture source.
///
/// Recorders use it only when a capture segment starts. This lets each WAV pad
/// to the same sample position even when ScreenCaptureKit starts later than the
/// microphone or a resume operation takes a little longer for one source.
final class CaptureClock: @unchecked Sendable {
  private let lock = NSLock()
  private var startedUptime: TimeInterval?
  private var pausedUptime: TimeInterval?
  private var accumulatedPause: TimeInterval = 0

  func start() {
    lock.withLock {
      startedUptime = ProcessInfo.processInfo.systemUptime
      pausedUptime = nil
      accumulatedPause = 0
    }
  }

  @discardableResult
  func pause() -> TimeInterval {
    lock.withLock {
      if pausedUptime == nil { pausedUptime = ProcessInfo.processInfo.systemUptime }
      return elapsedLocked(at: pausedUptime ?? ProcessInfo.processInfo.systemUptime)
    }
  }

  func resume() {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      if let pausedUptime { accumulatedPause += max(0, now - pausedUptime) }
      self.pausedUptime = nil
    }
  }

  func reset() {
    lock.withLock {
      startedUptime = nil
      pausedUptime = nil
      accumulatedPause = 0
    }
  }

  var elapsed: TimeInterval {
    lock.withLock {
      elapsedLocked(at: pausedUptime ?? ProcessInfo.processInfo.systemUptime)
    }
  }

  var samplePosition: Int { Int((elapsed * Double(WavFile.sampleRate)).rounded()) }

  private func elapsedLocked(at now: TimeInterval) -> TimeInterval {
    guard let startedUptime else { return 0 }
    return max(0, now - startedUptime - accumulatedPause)
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
