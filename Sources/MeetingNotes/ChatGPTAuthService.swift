import Foundation

actor ChatGPTAuthService {
  static let shared = ChatGPTAuthService()

  enum AuthError: LocalizedError {
    case codexUnavailable
    case commandFailed(String)
    case missingOutput

    var errorDescription: String? {
      switch self {
      case .codexUnavailable:
        "ChatGPT sign-in requires the ChatGPT app or Codex CLI on this Mac."
      case .commandFailed(let detail):
        detail.isEmpty ? "ChatGPT sign-in failed." : detail
      case .missingOutput:
        "ChatGPT did not return structured meeting notes."
      }
    }
  }

  struct CommandResult: Sendable {
    let status: Int32
    let output: String
  }

  private let fileManager = FileManager.default

  func isAuthenticated() async -> Bool {
    guard let executable = executableURL else { return false }
    guard let result = try? await run(executable, arguments: ["login", "status"]) else {
      return false
    }
    // The exit status is authoritative: `codex login status` exits non-zero
    // when signed out. The phrase check stays only as a defensive fallback
    // for builds that exit zero while reporting "Not logged in".
    return result.status == 0
      && !result.output.localizedCaseInsensitiveContains("not logged in")
  }

  func signIn() async throws {
    guard let executable = executableURL else { throw AuthError.codexUnavailable }
    let result = try await run(executable, arguments: ["login"])
    guard result.status == 0 else { throw AuthError.commandFailed(cleanError(result.output)) }
  }

  func signOut() async throws {
    guard let executable = executableURL else { throw AuthError.codexUnavailable }
    let result = try await run(executable, arguments: ["logout"])
    guard result.status == 0 else { throw AuthError.commandFailed(cleanError(result.output)) }
  }

  func generateStructuredOutput(
    prompt: String, schemaData: Data, model: String, reasoningEffort: String
  ) async throws -> Data {
    guard let executable = executableURL else { throw AuthError.codexUnavailable }
    let temporary = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporary) }
    let schemaURL = temporary.appending(path: "schema.json")
    let outputURL = temporary.appending(path: "output.json")
    try schemaData.write(to: schemaURL, options: .atomic)

    let instruction = Self.instruction(prompt: prompt)
    var arguments = [
      "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
      "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
    ]
    // An empty model means "use the ChatGPT default", so the flag is omitted
    // entirely rather than sent as an empty string.
    let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanModel.isEmpty { arguments += ["--model", cleanModel] }
    let cleanEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    // The value lands inside a TOML string; only known effort-name characters
    // may pass so quoting can never be broken from settings.
    if !cleanEffort.isEmpty,
      cleanEffort.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    {
      arguments += ["-c", "model_reasoning_effort=\"\(cleanEffort)\""]
    }
    arguments += [
      "--output-schema", schemaURL.path, "--output-last-message", outputURL.path,
      "-C", temporary.path, "-",
    ]
    let result = try await run(executable, arguments: arguments, input: Data(instruction.utf8))
    guard result.status == 0 else { throw AuthError.commandFailed(cleanError(result.output)) }
    guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
      throw AuthError.missingOutput
    }
    return data
  }

  nonisolated static func instruction(prompt: String) -> String {
    """
    \(prompt)

    Return only the requested structured JSON. Do not use tools, inspect files, or access the network for additional information.
    """
  }

  private var authHome: URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "MeetingNotes/ChatGPTAuth", directoryHint: .isDirectory)
  }

  private var executableURL: URL? {
    let home = fileManager.homeDirectoryForCurrentUser
    let candidates = [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      home.appending(path: ".local/bin/codex").path,
      home.appending(path: ".bun/bin/codex").path,
    ]
    return candidates.first(where: fileManager.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
  }

  private func run(
    _ executable: URL, arguments: [String], input: Data? = nil
  ) async throws -> CommandResult {
    try fileManager.createDirectory(
      at: authHome, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let logURL = fileManager.temporaryDirectory.appending(path: "meeting-notes-codex-\(UUID().uuidString).log")
    fileManager.createFile(atPath: logURL.path, contents: nil)
    let logHandle = try FileHandle(forWritingTo: logURL)
    defer {
      try? logHandle.close()
      try? fileManager.removeItem(at: logURL)
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = authHome.path
    process.environment = environment
    process.standardOutput = logHandle
    process.standardError = logHandle
    let inputPipe = Pipe()
    if input != nil { process.standardInput = inputPipe }

    return try await withCheckedThrowingContinuation { continuation in
      let resumeState = ResumeOnce()
      process.terminationHandler = { process in
        try? logHandle.synchronize()
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard resumeState.claim() else { return }
        continuation.resume(returning: CommandResult(
          status: process.terminationStatus, output: output))
      }
      do {
        try process.run()
      } catch {
        if resumeState.claim() { continuation.resume(throwing: error) }
        return
      }
      if let input {
        let writer = inputPipe.fileHandleForWriting
        // Write off the actor so a slow reader cannot block it, and use the
        // throwing write(contentsOf:) so a broken pipe (codex exiting before
        // consuming stdin) surfaces as a Swift error instead of an
        // uncatchable ObjC exception.
        DispatchQueue.global(qos: .utility).async {
          do {
            try writer.write(contentsOf: input)
            try writer.close()
          } catch {
            try? writer.close()
            guard resumeState.claim() else { return }
            continuation.resume(throwing: AuthError.commandFailed(
              "ChatGPT could not receive the request: \(error.localizedDescription)"))
          }
        }
      }
    }
  }

  private func cleanError(_ output: String) -> String {
    output.split(separator: "\n")
      .filter { !$0.contains("PATH aliases") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .suffix(3).joined(separator: " ")
  }
}

/// Guards a checked continuation against double resumption when both the
/// termination handler and the stdin writer race to report a failure.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if resumed { return false }
    resumed = true
    return true
  }
}
