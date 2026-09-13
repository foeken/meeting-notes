import Darwin
import Foundation

enum SyncSubprocess {
  private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
  }

  static func run(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
    timeout: Duration = .seconds(180), grace: Duration = .seconds(5)
  ) async throws {
    let cancellation = Cancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(with: Result {
            try execute(executable, arguments, environment: environment, timeout: timeout,
                        grace: grace, cancellation: cancellation)
          })
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private static func execute(
    _ executable: String, _ arguments: [String], environment: [String: String]?,
    timeout: Duration, grace: Duration, cancellation: Cancellation
  ) throws {
    if cancellation.isCancelled { throw CancellationError() }
    // An unlinked temporary file avoids pipe-buffer deadlocks and leaves no log on disk.
    var template = Array((NSTemporaryDirectory() + "meeting-sync-XXXXXX").utf8CString)
    let errorFD = mkstemp(&template)
    guard errorFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
    defer { close(errorFD) }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    func check(_ code: Int32) throws {
      if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(posix_spawn_file_actions_adddup2(&actions, errorFD, STDERR_FILENO))
    try check(posix_spawn_file_actions_addclose(&actions, errorFD))
    try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0))
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      env.forEach { free($0) }
    }
    var pid: pid_t = 0
    try argv.withUnsafeBufferPointer { args in
      try env.withUnsafeBufferPointer { vars in
        try check(posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, vars.baseAddress!))
      }
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var status: Int32 = 0
    while true {
      if cancellation.isCancelled || ContinuousClock.now >= deadline {
        kill(-pid, SIGTERM)
        let killDeadline = ContinuousClock.now.advanced(by: grace)
        while ContinuousClock.now < killDeadline { usleep(10_000) }
        // Keep the leader unreaped until group cleanup, preventing reuse of its PID.
        // Descendants that deliberately create another session are outside this group.
        kill(-pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if cancellation.isCancelled { throw CancellationError() }
        throw NSError(domain: "RemoteSync", code: -1001,
                      userInfo: [NSLocalizedDescriptionKey: "\((executable as NSString).lastPathComponent) timed out"])
      }
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid { break }
      if result < 0 && errno != EINTR {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      usleep(10_000)
    }
    guard status == 0 else {
      lseek(errorFD, 0, SEEK_SET)
      let data = try FileHandle(fileDescriptor: errorFD, closeOnDealloc: false).readToEnd() ?? Data()
      let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw NSError(domain: "RemoteSync", code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "Remote sync failed" : detail])
    }
  }
}
