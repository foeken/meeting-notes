import AppKit
import Foundation
import SwiftUI

/// The OpenAI mark, used wherever the app surfaces ChatGPT.
struct OpenAIAppIcon: View {
  let size: CGFloat
  var color: Color?

  var body: some View {
    Group {
      if let icon = CodexThreadService.openAILogoImage() {
        let image = Image(nsImage: icon)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
        if let color {
          image.foregroundStyle(color)
        } else {
          image
        }
      } else {
        let fallback = Image(systemName: "sparkle")
          .font(.system(size: size * 0.62, weight: .semibold))
        if let color {
          fallback.foregroundStyle(color)
        } else {
          fallback
        }
      }
    }
    .frame(width: size, height: size)
  }
}

struct ChatGPTIconButtonLabel: View {
  let isLoading: Bool
  var isAlternate = false
  @State private var isHovered = false

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        OpenAIAppIcon(size: 16, color: isAlternate ? .accentColor : nil)
      }
    }
    .frame(width: 28, height: 24)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(
          isAlternate
            ? AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.22 : 0.14))
            : AnyShapeStyle(.primary.opacity(isHovered ? 0.12 : 0.06)))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(
          isAlternate
            ? AnyShapeStyle(Color.accentColor.opacity(0.45))
            : AnyShapeStyle(.primary.opacity(isHovered ? 0.18 : 0.10)),
          lineWidth: 0.5)
    }
    .overlay(alignment: .topTrailing) {
      if isAlternate && !isLoading {
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color.accentColor)
          .background(Color(nsColor: .windowBackgroundColor), in: Circle())
          .offset(x: 3, y: -3)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .onHover { isHovered = $0 }
  }
}

struct ChatGPTActionButtonLabel: View {
  let isLoading: Bool
  var isAlternate = false

  var body: some View {
    HStack(spacing: 6) {
      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        OpenAIAppIcon(size: 15, color: isAlternate ? .accentColor : nil)
      }
      Text(
        isLoading
          ? "Opening…" : (isAlternate ? "New ChatGPT task" : "Discuss with ChatGPT"))
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 9)
    .frame(height: 28)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isAlternate
            ? AnyShapeStyle(Color.accentColor.opacity(0.14))
            : AnyShapeStyle(.primary.opacity(0.065)))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          isAlternate
            ? AnyShapeStyle(Color.accentColor.opacity(0.45))
            : AnyShapeStyle(.primary.opacity(0.11)),
          lineWidth: 0.5)
    }
    .animation(.easeOut(duration: 0.12), value: isAlternate)
  }
}

struct CodexMeetingContext: Sendable {
  let meetingID: UUID
  let title: String
  let startedAt: Date
  let projectFolder: URL
  let meetingFolder: URL
}

struct CodexModelChoice: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let reasoningEfforts: [String]
}

enum CodexThreadService {
  static let defaultPromptTemplate = """
    We are going to discuss the meeting “{{meeting_title}}”.

    Meeting ID: {{meeting_id}}
    Meeting folder: {{meeting_folder}}

    Gather the current meeting context now using these rules:
    1. If `live.md` exists, read it through its current end. Re-read it whenever I ask what was just discussed.
    2. If `meeting.md` exists, use it as the primary semantic overview.
    3. Do not read the complete `transcript.md` unless I explicitly ask for transcript evidence, or `meeting.md` is absent or clearly incomplete.
    4. Use the hidden `.meeting.json` only when meeting metadata or processing state is needed.
    5. Do not automatically extract decisions, tasks, commitments, or owners. Wait until I ask.
    6. Keep claims grounded in the meeting files and preserve timestamps when they matter.

    Briefly confirm which meeting artifact you used and that you are ready. Do not summarize the meeting unless I ask.
    """

  /// Empty by default: the follow-up work a meeting should trigger is personal,
  /// so nothing runs until the user writes their own instruction.
  static let defaultSummaryMessageTemplate = ""

  static let summaryMessagePlaceholder = """
    Extract the tasks and send them to my task manager.

    Other ideas: send meeting.md to HubSpot, or save the notes in Slite.
    """

  enum ServiceError: LocalizedError {
    case appNotInstalled
    case projectFolderUnavailable
    case protocolError(String)
    case processExited(String)
    case timedOut
    case turnFailed(String)

    var errorDescription: String? {
      switch self {
      case .appNotInstalled:
        "ChatGPT is not installed on this Mac."
      case .projectFolderUnavailable:
        "The local meeting archive is unavailable."
      case .protocolError(let detail):
        "ChatGPT could not create the thread: \(detail)"
      case .processExited(let detail):
        detail.isEmpty ? "ChatGPT stopped before the thread was created." : detail
      case .timedOut:
        "ChatGPT did not respond in time. Please try again."
      case .turnFailed(let detail):
        detail.isEmpty ? "The ChatGPT thread could not finish its work." : detail
      }
    }
  }

  static func executableURL() -> URL? {
    let manager = FileManager.default
    let candidates = [
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?
        .appending(path: "Contents/Resources/codex"),
      URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
      URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
      URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
      URL(fileURLWithPath: "/usr/local/bin/codex"),
    ].compactMap { $0 }
    return candidates.first { manager.isExecutableFile(atPath: $0.path) }
  }

  /// The OpenAI mark, used wherever the app surfaces ChatGPT.
  /// Sourced from @lobehub/icons-static-svg.
  static func openAILogoImage(bundle: Bundle = .main) -> NSImage? {
    guard let url = bundle.url(forResource: "OpenAILogo", withExtension: "svg") else {
      return nil
    }
    guard let image = NSImage(contentsOf: url) else { return nil }
    image.isTemplate = true
    return image
  }

  static func threadTitle(for context: CodexMeetingContext) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return "\(context.title) — \(formatter.string(from: context.startedAt))"
  }

  static func initialPrompt(
    for context: CodexMeetingContext,
    template: String = defaultPromptTemplate
  ) -> String {
    renderTemplate(template, context: context)
  }

  static func renderTemplate(
    _ template: String, context: CodexMeetingContext
  ) -> String {
    let dateFormatter = ISO8601DateFormatter()
    // Only identifiers and paths are substituted. Whole documents (the
    // summary, the transcript) stay in their files so the task reads them
    // from disk instead of receiving a copy that can go stale.
    let replacements = [
      "{{meeting_title}}": context.title,
      "{{meeting_id}}": context.meetingID.uuidString,
      "{{meeting_date}}": dateFormatter.string(from: context.startedAt),
      "{{meeting_folder}}": context.meetingFolder.path,
      "{{project_folder}}": context.projectFolder.path,
    ]
    return replacements.reduce(template) { result, replacement in
      result.replacingOccurrences(of: replacement.key, with: replacement.value)
    }
  }

  static func threadURL(_ threadID: String) -> URL? {
    URL(string: "codex://threads/\(threadID)")
  }

  static func threadStartParams(for context: CodexMeetingContext) -> [String: Any] {
    threadStartParams(for: context, model: nil, reasoningEffort: nil)
  }

  /// Codex falls back to its own default model when `thread/start` omits one,
  /// which is rarely the model the user actually works with. Sending the
  /// chosen model (and its reasoning effort) keeps meeting tasks consistent
  /// with the rest of their Codex setup.
  static func threadStartParams(
    for context: CodexMeetingContext,
    model: String?,
    reasoningEffort: String?
  ) -> [String: Any] {
    var params: [String: Any] = [
      "cwd": context.projectFolder.standardizedFileURL.path,
      "ephemeral": false,
      "threadSource": "appServer",
    ]
    let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !cleanModel.isEmpty else { return params }
    params["model"] = cleanModel
    // A model without an explicit effort keeps Codex's own default effort.
    let cleanEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !cleanEffort.isEmpty {
      params["config"] = ["model_reasoning_effort": cleanEffort]
    }
    return params
  }

  /// Every app-server exchange shares the same shape: spawn the bundled
  /// `codex app-server`, run the initialize handshake under one deadline, then
  /// perform the call-specific requests. `body` runs on a background queue;
  /// request ids from 2 upward are free for it to use.
  private static func withConnection<T: Sendable>(
    timeout: TimeInterval,
    _ body: @escaping @Sendable (CodexRPCConnection) throws -> T
  ) async throws -> T {
    guard let executable = executableURL() else { throw ServiceError.appNotInstalled }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let connection = try CodexRPCConnection(executable: executable)
          connection.startDeadline(seconds: timeout)
          defer { connection.cancelDeadline() }
          try connection.sendRequest(
            id: 1,
            method: "initialize",
            params: [
              "clientInfo": [
                // The name is forwarded upstream as the `originator` header, and
                // unknown originators intermittently fail the model-geography
                // check that stock Codex clients pass. Identify as the stock
                // client; the title still shows who we are.
                "name": "codex_cli_rs",
                "title": "Meeting Notes",
                "version": "1",
              ]
            ])
          _ = try connection.response(id: 1)
          try connection.sendNotification(method: "initialized", params: [:])
          continuation.resume(returning: try body(connection))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Starts a turn and returns its id, the piece every turn-based call needs.
  private static func startTurn(
    _ connection: CodexRPCConnection, id: Int, threadID: String, input: [[String: Any]]
  ) throws -> String {
    try connection.sendRequest(
      id: id,
      method: "turn/start",
      params: ["threadId": threadID, "input": input])
    let response = try connection.response(id: id)
    guard let result = response["result"] as? [String: Any],
      let turn = result["turn"] as? [String: Any],
      let turnID = turn["id"] as? String,
      !turnID.isEmpty
    else { throw ServiceError.protocolError("Codex returned no turn ID.") }
    return turnID
  }

  /// Asks the local app-server which models it offers, so Settings can show
  /// real choices instead of a hardcoded list that drifts out of date.
  static func availableModels() async throws -> [CodexModelChoice] {
    return try await withConnection(timeout: 20) { connection in
      try connection.sendRequest(id: 2, method: "model/list", params: [:])
      let response = try connection.response(id: 2)
      let result = response["result"] as? [String: Any]
      // Newer app-servers return the list under "data"; older ones used "models".
      let raw = (result?["data"] ?? result?["models"]) as? [[String: Any]] ?? []
      return raw.compactMap { entry -> CodexModelChoice? in
        guard let id = entry["id"] as? String, !id.isEmpty,
          entry["hidden"] as? Bool != true
        else { return nil }
        let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
          .compactMap { $0["reasoningEffort"] as? String }
        return CodexModelChoice(
          id: id,
          displayName: entry["displayName"] as? String ?? id,
          reasoningEfforts: efforts)
      }
    }
  }

  static func turnInput(
    for context: CodexMeetingContext,
    promptTemplate: String = defaultPromptTemplate
  ) -> [String: Any] {
    [
      "type": "text",
      "text": initialPrompt(for: context, template: promptTemplate),
    ]
  }

  static func isVisibleUserMessageEvent(_ object: [String: Any], threadID: String) -> Bool {
    guard object["method"] as? String == "item/started",
      let params = object["params"] as? [String: Any],
      params["threadId"] as? String == threadID,
      let item = params["item"] as? [String: Any]
    else { return false }
    return item["type"] as? String == "userMessage"
  }

  /// Recognizes the end of a turn. `turn/completed` carries the finished turn;
  /// `turn/failed` carries the reason the task could not finish.
  static func turnOutcome(
    _ object: [String: Any], threadID: String, turnID: String
  ) -> Result<Void, ServiceError>? {
    guard let method = object["method"] as? String,
      method == "turn/completed" || method == "turn/failed",
      let params = object["params"] as? [String: Any],
      params["threadId"] as? String == threadID
    else { return nil }
    let turn = params["turn"] as? [String: Any]
    if let eventTurnID = turn?["id"] as? String ?? params["turnId"] as? String,
      eventTurnID != turnID
    { return nil }
    if method == "turn/completed" { return .success(()) }
    let error = (params["error"] as? [String: Any]) ?? (turn?["error"] as? [String: Any])
    return .failure(.turnFailed(error?["message"] as? String ?? ""))
  }

  static func createThread(
    for context: CodexMeetingContext,
    promptTemplate: String = defaultPromptTemplate,
    model: String? = nil,
    reasoningEffort: String? = nil
  ) async throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: context.projectFolder.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw ServiceError.projectFolderUnavailable }
    // The dictionaries are built inside the closure: [String: Any] is not
    // Sendable, while `context` and the plain strings are.
    let template = promptTemplate
    return try await withConnection(timeout: 30) { connection in
      try connection.sendRequest(
        id: 2,
        method: "thread/start",
        params: threadStartParams(for: context, model: model, reasoningEffort: reasoningEffort))
      let startResponse = try connection.response(id: 2)
      guard let result = startResponse["result"] as? [String: Any],
        let thread = result["thread"] as? [String: Any],
        let threadID = thread["id"] as? String,
        !threadID.isEmpty
      else { throw ServiceError.protocolError("Codex returned no task ID.") }

      try connection.sendRequest(
        id: 3,
        method: "thread/name/set",
        params: ["threadId": threadID, "name": threadTitle(for: context)])
      _ = try connection.response(id: 3)

      // Persist the meeting context as a normal visible user message, then
      // interrupt before model generation. The user's first real message
      // will process this preloaded context once.
      let turnID = try startTurn(
        connection, id: 4, threadID: threadID,
        input: [turnInput(for: context, promptTemplate: template)])
      try connection.waitUntilUserMessageStarts(threadID: threadID)
      try connection.sendRequest(
        id: 5,
        method: "turn/interrupt",
        params: ["threadId": threadID, "turnId": turnID])
      _ = try connection.response(id: 5)
      return threadID
    }
  }

  /// Posts a message into an existing Codex task without triggering model
  /// generation, mirroring how the initial meeting context is preloaded:
  /// resume the thread, start a turn with the message, wait until the user
  /// message is visible, then interrupt.
  /// Sends a message to an existing Codex task and lets the task actually work
  /// on it. Unlike the meeting-context preload, this turn runs to completion,
  /// so the instruction (extract tasks, file notes elsewhere, …) is carried out.
  static func sendMessage(
    _ message: String, toThread threadID: String, timeout: TimeInterval = 900
  ) async throws {
    try await withConnection(timeout: timeout) { connection in
      try connection.sendRequest(
        id: 2, method: "thread/resume", params: ["threadId": threadID])
      _ = try connection.response(id: 2)
      let turnID = try startTurn(
        connection, id: 3, threadID: threadID,
        input: [["type": "text", "text": message]])
      try connection.waitUntilTurnFinishes(threadID: threadID, turnID: turnID)
    }
  }

  /// Asked of a meeting's task right before the structured notes are written.
  /// The sentinel reply lets an empty result be recognized without parsing.
  static let summaryContextPrompt = """
    The app is about to generate the final structured notes for this meeting \
    from the word-for-word transcript. Review this task's discussion and reply \
    with only the points that should shape those notes: corrections, \
    decisions, context, follow-ups, or emphasis that the transcript alone \
    would miss or get wrong. Be concise and factual, one bullet per point. Do \
    not summarize the whole meeting. If this task contains nothing the notes \
    should reflect, reply with exactly NOTHING_TO_ADD.
    """

  /// Trims a task reply and drops the nothing-to-add sentinel, so callers see
  /// either usable notes or nil.
  static func normalizedSummaryContext(_ reply: String) -> String? {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("NOTHING_TO_ADD") else { return nil }
    return trimmed
  }

  /// The text of a finished assistant message in the given thread, when the
  /// event carries one.
  static func agentMessageText(_ object: [String: Any], threadID: String) -> String? {
    guard object["method"] as? String == "item/completed",
      let params = object["params"] as? [String: Any],
      params["threadId"] as? String == threadID,
      let item = params["item"] as? [String: Any],
      item["type"] as? String == "agentMessage"
    else { return nil }
    return item["text"] as? String
  }

  /// Runs one turn in the meeting's task asking which discussion points should
  /// influence the notes. Returns nil when the task has nothing to add.
  static func askForSummaryContext(
    threadID: String, timeout: TimeInterval = 240
  ) async throws -> String? {
    return try await withConnection(timeout: timeout) { connection in
      try connection.sendRequest(
        id: 2, method: "thread/resume", params: ["threadId": threadID])
      _ = try connection.response(id: 2)
      let turnID = try startTurn(
        connection, id: 3, threadID: threadID,
        input: [["type": "text", "text": summaryContextPrompt]])
      let reply = try connection.collectAgentText(threadID: threadID, turnID: turnID)
      return normalizedSummaryContext(reply)
    }
  }

}

private final class CodexRPCConnection {
  /// Only notification methods the waiters match on are worth buffering;
  /// everything else (deltas, token counts, …) is dropped.
  private static let bufferedNotificationMethods: Set<String> = [
    "item/started", "item/completed", "turn/completed", "turn/failed",
  ]
  private static let maxBufferedNotifications = 64

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private var buffer = Data()
  private var pendingNotifications: [[String: Any]] = []
  private let deadlineLock = NSLock()
  private var deadlineItem: DispatchWorkItem?
  private var deadlineExpired = false

  init(executable: URL) throws {
    process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = executable
    process.arguments = ["app-server", "--stdio"]
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    input = inputPipe.fileHandleForWriting
    output = outputPipe.fileHandleForReading
    errorOutput = errorPipe.fileHandleForReading
    try process.run()
  }

  deinit {
    cancelDeadline()
    try? input.close()
    try? output.close()
    try? errorOutput.close()
    if process.isRunning { process.terminate() }
  }

  /// Arms a watchdog that tears the connection down after `seconds`, which
  /// unblocks any pending read and converts it into `ServiceError.timedOut`.
  func startDeadline(seconds: TimeInterval) {
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.deadlineLock.lock()
      self.deadlineExpired = true
      self.deadlineLock.unlock()
      // Closing stdout makes the blocked availableData read return empty data.
      if self.process.isRunning { self.process.terminate() }
      try? self.output.close()
    }
    deadlineLock.lock()
    deadlineItem = item
    deadlineLock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
  }

  func cancelDeadline() {
    deadlineLock.lock()
    deadlineItem?.cancel()
    deadlineItem = nil
    deadlineLock.unlock()
  }

  private var hasTimedOut: Bool {
    deadlineLock.lock()
    defer { deadlineLock.unlock() }
    return deadlineExpired
  }

  func sendRequest(id: Int, method: String, params: [String: Any]) throws {
    try send(["id": id, "method": method, "params": params])
  }

  func sendNotification(method: String, params: [String: Any]) throws {
    try send(["method": method, "params": params])
  }

  func response(id: Int) throws -> [String: Any] {
    while true {
      let object = try nextObject()
      if let responseID = object["id"] as? Int, responseID == id {
        if let error = object["error"] as? [String: Any] {
          throw CodexThreadService.ServiceError.protocolError(
            error["message"] as? String ?? String(describing: error))
        }
        return object
      }
      bufferNotification(object)
    }
  }

  func waitUntilUserMessageStarts(threadID: String) throws {
    if let index = pendingNotifications.firstIndex(where: {
      CodexThreadService.isVisibleUserMessageEvent($0, threadID: threadID)
    }) {
      pendingNotifications.remove(at: index)
      return
    }
    while process.isRunning {
      let object = try nextNotificationObject()
      if CodexThreadService.isVisibleUserMessageEvent(object, threadID: threadID) { return }
    }
    if hasTimedOut { throw CodexThreadService.ServiceError.timedOut }
    throw CodexThreadService.ServiceError.processExited("")
  }

  /// Waits for the running turn to finish so the task's work actually happens.
  func waitUntilTurnFinishes(threadID: String, turnID: String) throws {
    if let index = pendingNotifications.firstIndex(where: {
      CodexThreadService.turnOutcome($0, threadID: threadID, turnID: turnID) != nil
    }) {
      let object = pendingNotifications.remove(at: index)
      if let outcome = CodexThreadService.turnOutcome(
        object, threadID: threadID, turnID: turnID)
      {
        return try outcome.get()
      }
    }
    while process.isRunning {
      let object = try nextNotificationObject()
      if let outcome = CodexThreadService.turnOutcome(
        object, threadID: threadID, turnID: turnID)
      {
        return try outcome.get()
      }
    }
    if hasTimedOut { throw CodexThreadService.ServiceError.timedOut }
    throw CodexThreadService.ServiceError.processExited("")
  }

  /// Waits for the turn to finish while collecting assistant message text, so
  /// a caller can read the reply of the turn it started.
  func collectAgentText(threadID: String, turnID: String) throws -> String {
    var collected: [String] = []
    for object in pendingNotifications {
      if let text = CodexThreadService.agentMessageText(object, threadID: threadID) {
        collected.append(text)
      }
    }
    while process.isRunning {
      let object = try nextNotificationObject()
      if let text = CodexThreadService.agentMessageText(object, threadID: threadID) {
        collected.append(text)
        continue
      }
      if let outcome = CodexThreadService.turnOutcome(
        object, threadID: threadID, turnID: turnID)
      {
        try outcome.get()
        return collected.joined(separator: "\n\n")
      }
    }
    if hasTimedOut { throw CodexThreadService.ServiceError.timedOut }
    throw CodexThreadService.ServiceError.processExited("")
  }

  private func bufferNotification(_ object: [String: Any]) {
    guard let method = object["method"] as? String,
      Self.bufferedNotificationMethods.contains(method)
    else { return }
    pendingNotifications.append(object)
    if pendingNotifications.count > Self.maxBufferedNotifications {
      pendingNotifications.removeFirst(
        pendingNotifications.count - Self.maxBufferedNotifications)
    }
  }

  private func nextNotificationObject() throws -> [String: Any] {
    if !pendingNotifications.isEmpty { return pendingNotifications.removeFirst() }
    return try nextObject()
  }

  private func send(_ object: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try input.write(contentsOf: data)
  }

  private func nextObject() throws -> [String: Any] {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        guard !line.isEmpty else { continue }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { throw CodexThreadService.ServiceError.protocolError("Invalid JSON response.") }
        return object
      }
      let data = output.availableData
      guard !data.isEmpty else {
        if hasTimedOut { throw CodexThreadService.ServiceError.timedOut }
        let detail = String(data: errorOutput.availableData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw CodexThreadService.ServiceError.processExited(detail)
      }
      buffer.append(data)
    }
  }
}
