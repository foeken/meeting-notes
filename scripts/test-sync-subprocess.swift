// Run: swiftc -parse-as-library Sources/MeetingNotes/SyncSubprocess.swift scripts/test-sync-subprocess.swift -o /tmp/test-sync-subprocess && /tmp/test-sync-subprocess
import Foundation

@main struct SubprocessCheck {
  static func main() async throws {
    try await SyncSubprocess.run("/bin/sh", ["-c", "exit 0"])
    do {
      try await SyncSubprocess.run("/bin/sh", ["-c", "echo expected-error >&2; exit 7"])
      fatalError("Expected failure")
    } catch {
      precondition(error.localizedDescription.contains("expected-error"))
    }
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    // A child ignores TERM and tries to write after the parent has exited.
    let command = "(trap '' TERM; sleep 1; touch '\(marker.path)') & wait"
    do {
      try await SyncSubprocess.run("/bin/sh", ["-c", command],
                                   timeout: .milliseconds(100), grace: .milliseconds(100))
      fatalError("Expected timeout")
    } catch {
      precondition((error as NSError).code == -1001)
    }
    try await Task.sleep(for: .milliseconds(1200))
    precondition(!FileManager.default.fileExists(atPath: marker.path), "Child survived timeout")
    let task = Task {
      try await SyncSubprocess.run("/bin/sh", ["-c", command], grace: .milliseconds(100))
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      try await task.value
      fatalError("Expected cancellation")
    } catch is CancellationError {}
    try await Task.sleep(for: .milliseconds(1200))
    precondition(!FileManager.default.fileExists(atPath: marker.path), "Child survived cancellation")
    print("Subprocess checks passed")
  }
}
