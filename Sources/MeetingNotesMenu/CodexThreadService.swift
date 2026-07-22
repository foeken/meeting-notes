import AppKit
import Foundation
import SwiftUI

struct CodexAppIcon: View {
  let size: CGFloat
  var color: Color?

  var body: some View {
    Group {
      if let icon = CodexThreadService.logoImage() {
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

struct CodexIconButtonLabel: View {
  let isLoading: Bool
  @State private var isHovered = false

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        CodexAppIcon(size: 16)
      }
    }
    .frame(width: 28, height: 24)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.primary.opacity(isHovered ? 0.12 : 0.06))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(.primary.opacity(isHovered ? 0.18 : 0.10), lineWidth: 0.5)
    }
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .onHover { isHovered = $0 }
  }
}

struct CodexActionButtonLabel: View {
  let isLoading: Bool

  var body: some View {
    HStack(spacing: 6) {
      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        CodexAppIcon(size: 15)
      }
      Text(isLoading ? "Opening…" : "Discuss")
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 9)
    .frame(height: 28)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.primary.opacity(0.065))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(.primary.opacity(0.11), lineWidth: 0.5)
    }
  }
}

struct CodexMeetingContext: Sendable {
  let meetingID: UUID
  let title: String
  let startedAt: Date
  let projectFolder: URL
  let meetingFolder: URL
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
    4. Use `meeting.json` only when meeting metadata or processing state is needed.
    5. Do not automatically extract decisions, tasks, commitments, or owners. Wait until I ask.
    6. Keep claims grounded in the meeting files and preserve timestamps when they matter.

    Briefly confirm which meeting artifact you used and that you are ready. Do not summarize the meeting unless I ask.
    """

  enum ServiceError: LocalizedError {
    case appNotInstalled
    case projectFolderUnavailable
    case protocolError(String)
    case processExited(String)

    var errorDescription: String? {
      switch self {
      case .appNotInstalled:
        "Codex is not installed on this Mac."
      case .projectFolderUnavailable:
        "The local meeting archive is unavailable."
      case .protocolError(let detail):
        "Codex could not create the task: \(detail)"
      case .processExited(let detail):
        detail.isEmpty ? "Codex stopped before the task was created." : detail
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

  static func logoImage(bundle: Bundle = .main) -> NSImage? {
    guard let url = bundle.url(forResource: "CodexLogo", withExtension: "svg") else {
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
    let dateFormatter = ISO8601DateFormatter()
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

  static func newThreadURL(for context: CodexMeetingContext) -> URL? {
    var components = URLComponents()
    components.scheme = "codex"
    components.host = "threads"
    components.path = "/new"
    components.queryItems = [
      URLQueryItem(name: "path", value: context.projectFolder.path),
      URLQueryItem(name: "prompt", value: initialPrompt(for: context)),
    ]
    return components.url
  }

  static func threadStartParams(for context: CodexMeetingContext) -> [String: Any] {
    [
      "cwd": context.projectFolder.standardizedFileURL.path,
      "ephemeral": false,
      "threadSource": "appServer",
    ]
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

  static func createThread(
    for context: CodexMeetingContext,
    promptTemplate: String = defaultPromptTemplate
  ) async throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: context.projectFolder.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw ServiceError.projectFolderUnavailable }
    guard let executable = executableURL() else { throw ServiceError.appNotInstalled }

    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let connection = try CodexRPCConnection(executable: executable)
          try connection.sendRequest(
            id: 1,
            method: "initialize",
            params: [
              "clientInfo": [
                "name": "meeting-notes-menu",
                "title": "Meeting Notes",
                "version": "1",
              ]
            ])
          _ = try connection.response(id: 1)
          try connection.sendNotification(method: "initialized", params: [:])

          try connection.sendRequest(
            id: 2,
            method: "thread/start",
            params: threadStartParams(for: context))
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
          try connection.sendRequest(
            id: 4,
            method: "turn/start",
            params: [
              "threadId": threadID,
              "input": [turnInput(for: context, promptTemplate: promptTemplate)],
            ])
          let turnResponse = try connection.response(id: 4)
          guard let turnResult = turnResponse["result"] as? [String: Any],
            let turn = turnResult["turn"] as? [String: Any],
            let turnID = turn["id"] as? String,
            !turnID.isEmpty
          else { throw ServiceError.protocolError("Codex returned no turn ID.") }
          try connection.waitUntilUserMessageStarts(threadID: threadID)
          try connection.sendRequest(
            id: 5,
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID])
          _ = try connection.response(id: 5)
          continuation.resume(returning: threadID)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

}

private final class CodexRPCConnection {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let errorOutput: FileHandle
  private var buffer = Data()
  private var pendingNotifications: [[String: Any]] = []

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
    try? input.close()
    try? output.close()
    try? errorOutput.close()
    if process.isRunning { process.terminate() }
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
      if object["method"] != nil { pendingNotifications.append(object) }
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
    throw CodexThreadService.ServiceError.processExited("")
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
        let detail = String(data: errorOutput.availableData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw CodexThreadService.ServiceError.processExited(detail)
      }
      buffer.append(data)
    }
  }
}
