import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var model: AppModel
  @State private var selection: SettingsPane = .general

  var body: some View {
    HSplitView {
      List(SettingsPane.allCases, selection: $selection) { pane in
        sidebarLabel(for: pane)
          .tag(pane)
      }
      .listStyle(.sidebar)
      .frame(minWidth: 150, idealWidth: 170, maxWidth: 200)

      Group {
        switch selection {
        case .general:
          GeneralSettingsPane(model: model)
        case .storage:
          StorageSettingsPane(model: model)
        case .hooks:
          HookSettingsPane(model: model)
        case .transcriptions:
          TranscriptionsSettingsPane(model: model)
        case .microphone:
          MicrophoneSettingsPane(model: model)
        case .tana:
          TanaSettingsPane(model: model)
        case .dictionary:
          DictionarySettingsPane(model: model)
        case .codex:
          CodexSettingsPane(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(
      minWidth: 640, idealWidth: 860, maxWidth: .infinity,
      minHeight: 480, idealHeight: 640, maxHeight: .infinity)
    .background(SettingsWindowConfigurator())
    .onAppear { selection = .general }
  }

  @ViewBuilder
  private func sidebarLabel(for pane: SettingsPane) -> some View {
    if pane == .codex {
      CodexSidebarLabel(title: pane.title, isSelected: selection == pane)
    } else {
      Label(pane.title, systemImage: pane.systemImage)
    }
  }
}

private struct CodexSidebarLabel: View {
  let title: String
  let isSelected: Bool
  @State private var windowIsKey = true

  private var isHighlighted: Bool { isSelected && windowIsKey }

  var body: some View {
    Label {
      if isHighlighted {
        Text(title)
      } else {
        Text(title)
          .font(.body.weight(.regular))
      }
    } icon: {
      CodexAppIcon(
        size: 16,
        color: isHighlighted ? .white : .accentColor)
    }
    .background(WindowKeyObserver(isKey: $windowIsKey))
  }
}

private struct WindowKeyObserver: NSViewRepresentable {
  @Binding var isKey: Bool

  func makeNSView(context: Context) -> KeyObservingView {
    let view = KeyObservingView()
    view.onChange = { isKey = $0 }
    return view
  }

  func updateNSView(_ nsView: KeyObservingView, context: Context) {
    nsView.onChange = { isKey = $0 }
  }

  final class KeyObservingView: NSView {
    var onChange: ((Bool) -> Void)?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers.removeAll()
      guard let window else { return }
      let center = NotificationCenter.default
      let initialState = window.isKeyWindow
      DispatchQueue.main.async { [weak self] in self?.onChange?(initialState) }
      observers.append(
        center.addObserver(
          forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.onChange?(true) }
        })
      observers.append(
        center.addObserver(
          forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.onChange?(false) }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case codex
  case dictionary
  case microphone
  case transcriptions
  case storage
  case hooks
  case tana

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .storage: "Storage"
    case .hooks: "Hooks"
    case .transcriptions: "Transcriptions"
    case .microphone: "Microphone"
    case .tana: "Tana"
    case .dictionary: "Dictionary"
    case .codex: "Codex"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .storage: "externaldrive"
    case .hooks: "terminal"
    case .transcriptions: "text.alignleft"
    case .microphone: "mic"
    case .tana: "point.3.connected.trianglepath.dotted"
    case .dictionary: "character.book.closed"
    case .codex: "terminal"
    }
  }
}

private struct SettingsPaneHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.title2.weight(.semibold))
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

private struct GeneralSettingsPane: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "General",
          subtitle: "Configure meeting processing and automatic detection."
        )

        Divider()

        Text("ChatGPT")
          .font(.headline)

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Image(systemName: model.chatGPTAuthenticated ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(model.chatGPTAuthenticated ? .green : .secondary)
              Text(model.chatGPTAuthenticated ? "Connected" : "Not connected")
                .font(.body.weight(.medium))
            }
            Text(model.chatGPTAuthStatusText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          if model.chatGPTAuthenticated {
            Button("Sign out", action: model.signOutOfChatGPT)
              .disabled(model.chatGPTAuthInProgress)
          } else {
            Button("Sign in with ChatGPT", action: model.signInToChatGPT)
              .buttonStyle(.borderedProminent)
              .disabled(model.chatGPTAuthInProgress)
          }
        }

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Summary language")
              .font(.body.weight(.medium))
            Text("The word-for-word transcript stays in its original language.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Picker("Summary language", selection: Binding(
            get: { model.meetingNotesLanguage },
            set: { model.setMeetingNotesLanguage($0) }
          )) {
            ForEach(MeetingNotesLanguage.allCases) { language in
              Text(language.label).tag(language)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        }

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Detect video meetings")
              .font(.body.weight(.medium))
            Text("Offer to record when the camera and microphone activate in Zoom, Chrome, Teams, FaceTime, Slack, or WhatsApp.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Toggle("Detect video meetings", isOn: Binding(
            get: { model.meetingDetectionEnabled },
            set: { model.setMeetingDetectionEnabled($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        Label(
          "Detection stays on this Mac. Camera activity alone never starts a recording.",
          systemImage: "hand.raised"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()

        VStack(alignment: .leading, spacing: 4) {
          Text("Ignore calendar events")
            .font(.body.weight(.medium))
          Text("Events whose title contains one of these words are never suggested as meetings. Separate words with commas.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          TextField("Block, Focus, Lunch", text: $model.ignoredMeetingTitlesDraft)
            .textFieldStyle(.roundedBorder)
            .onChange(of: model.ignoredMeetingTitlesDraft) {
              model.persistIgnoredMeetingTitles()
            }
        }

        Divider()

        Text("Updates")
          .font(.headline)

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Update channel")
              .font(.body.weight(.medium))
            Text(model.updateChannel.explanation)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Picker("Update channel", selection: Binding(
            get: { model.updateChannel },
            set: { model.setUpdateChannel($0) }
          )) {
            ForEach(UpdateChannel.allCases) { channel in
              Text(channel.label).tag(channel)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        }

        Label(
          "Beta builds are signed the same way, but they are tested less. Switching back to stable keeps the beta you already installed until the next stable release replaces it.",
          systemImage: "flask"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(28)
    }
  }

}

private struct CodexSettingsPane: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "Codex",
          subtitle: "Customize how new meeting tasks are prepared in Codex."
        )

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Create tasks automatically")
              .font(.body.weight(.medium))
            Text("Start a Codex task in the background whenever a recording begins.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Toggle("Create tasks automatically", isOn: Binding(
            get: { model.codexAutoCreateThreads },
            set: { model.setCodexAutoCreateThreads($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
              Text("Model")
                .gridColumnAlignment(.trailing)
              HStack(spacing: 8) {
                Picker("Model", selection: Binding(
                  get: { model.codexModel },
                  set: { model.setCodexModel($0) }
                )) {
                  Text("Codex default").tag("")
                  ForEach(model.codexAvailableModels) { choice in
                    Text(choice.displayName).tag(choice.id)
                  }
                }
                .labelsHidden()
                .fixedSize()

                if model.codexModelsLoading {
                  ProgressView().controlSize(.small)
                }
              }
            }

            if !model.codexReasoningEffortChoices.isEmpty {
              GridRow {
                Text("Reasoning")
                  .gridColumnAlignment(.trailing)
                Picker("Reasoning", selection: Binding(
                  get: { model.codexReasoningEffort },
                  set: { model.setCodexReasoningEffort($0) }
                )) {
                  Text("Model default").tag("")
                  ForEach(model.codexReasoningEffortChoices, id: \.self) { effort in
                    Text(effort.capitalized).tag(effort)
                  }
                }
                .labelsHidden()
                .fixedSize()
              }
            }
          }
          .controlSize(.large)

          Text("New meeting tasks use this model. The list comes from Codex itself, so it stays current. Codex default lets Codex choose.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if !model.codexModelStatusText.isEmpty {
            Text(model.codexModelStatusText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
          Text("Meeting task prompt")
            .font(.headline)
          Text("Sent when a new Codex task is created for a meeting. Existing tasks are not changed.")
            .font(.caption)
            .foregroundStyle(.secondary)

          GrowingTextEditor(text: $model.codexPromptDraft, minHeight: 200)
            .padding(2)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
            }
            .onChange(of: model.codexPromptDraft) {
              model.persistCodexPromptDraft()
            }

          Text("Available placeholders: {{meeting_title}}, {{meeting_id}}, {{meeting_date}}, {{meeting_folder}}, {{project_folder}}")
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

          HStack {
            if !model.codexPromptStatusText.isEmpty {
              Text(model.codexPromptStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore Default", action: model.restoreDefaultCodexPrompt)
          }
        }

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Run a task after the notes are ready")
                .font(.body.weight(.medium))
              Text("Sends your instruction to the meeting's Codex task and lets it do the work.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Run a task after the notes are ready", isOn: Binding(
              get: { model.codexSummaryMessageEnabled },
              set: { model.setCodexSummaryMessageEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
          }

          if model.codexSummaryMessageEnabled {
            ZStack(alignment: .topLeading) {
              GrowingTextEditor(text: $model.codexSummaryMessageDraft, minHeight: 120)
                .padding(2)
                .background(
                  Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
                }
                .onChange(of: model.codexSummaryMessageDraft) {
                  model.persistCodexSummaryMessageDraft()
                }

              if model.codexSummaryMessageDraft.isEmpty {
                Text(CodexThreadService.summaryMessagePlaceholder)
                  .font(.system(.body, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .padding(.horizontal, 13)
                  .padding(.vertical, 12)
                  .allowsHitTesting(false)
              }
            }

            Text("Leave empty to do nothing. The same placeholders are available: {{meeting_title}}, {{meeting_id}}, {{meeting_date}}, {{meeting_folder}}, {{project_folder}}.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)

            if !model.codexSummaryMessageStatusText.isEmpty {
              Text(model.codexSummaryMessageStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(28)
    }
    .onAppear { model.refreshCodexModels() }
  }
}

private struct StorageSettingsPane: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "Storage",
          subtitle: "Meetings are always stored locally. Optionally sync a copy to another Mac."
        )

        Divider()

        Text("Local archive")
          .font(.headline)

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
          GridRow {
            Text("Folder")
              .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
              TextField("Meeting Notes", text: $model.localArchivePathDraft)
              Button("Choose…", action: model.chooseLocalArchiveDirectory)
            }
          }
        }
        .controlSize(.large)

        Text(model.keepAudioAfterProcessing
          ? "Finished notes and retained audio are saved here."
          : "Finished notes are saved here. Audio is deleted after successful processing.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Divider()

        Text("Disk usage")
          .font(.headline)

        if let usage = model.storageUsage {
          StorageUsageBar(usage: usage)

          HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Clean up audio")
                .font(.body.weight(.medium))
              Text("Deletes audio recordings of finished meetings. Recovery audio for unfinished captures is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(model.audioCleanupInProgress ? "Cleaning up…" : "Clean Up…") {
              model.requestAudioCleanup()
            }
            .disabled(model.audioCleanupInProgress || usage.audioBytes == 0)
          }

          if !model.audioCleanupStatusText.isEmpty {
            Text(model.audioCleanupStatusText)
              .font(.caption)
              .foregroundStyle(
                model.audioCleanupStatusText.contains("pending") ? .orange : .secondary)
          }
        } else {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Measuring…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Sync to a remote Mac")
              .font(.body.weight(.medium))
            Text("Send a copy over SSH. SSH key authentication must be set up first.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Sync to a remote Mac", isOn: $model.remoteSyncEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: model.remoteSyncEnabled) {
              if !model.remoteSyncEnabled, model.postMeetingHookLocation == .remote {
                model.postMeetingHookLocation = .disabled
                model.schedulePostMeetingHookSettingsSave()
              }
            }
        }

        if model.remoteSyncEnabled {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
              Text("Server address")
                .gridColumnAlignment(.trailing)
              TextField("username@example.com", text: $model.remoteHostDraft)
            }
            GridRow {
              Text("Folder")
                .gridColumnAlignment(.trailing)
              TextField("~/MeetingNotes", text: $model.remotePathDraft)
            }
          }
          .controlSize(.large)
        }

        if let error = model.archiveSettingsValidationError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        }

        if !model.settingsStatusText.isEmpty {
          Text(model.settingsStatusText)
            .font(.caption)
            .foregroundStyle(model.settingsStatusText.contains("failed") ? .red : .secondary)
        }
      }
      .padding(28)
    }
    .onChange(of: model.localArchivePathDraft, model.scheduleArchiveSettingsSave)
    .onChange(of: model.remoteSyncEnabled, model.scheduleArchiveSettingsSave)
    .onChange(of: model.remoteHostDraft, model.scheduleArchiveSettingsSave)
    .onChange(of: model.remotePathDraft, model.scheduleArchiveSettingsSave)
    .onAppear(perform: model.refreshStorageUsage)
  }

}

/// A macOS-style segmented capacity bar: documents, then audio, on a neutral
/// track, with a legend underneath.
private struct StorageUsageBar: View {
  let usage: MeetingStorageUsage

  private func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      GeometryReader { geometry in
        let total = max(Double(usage.totalBytes), 1)
        let documentWidth = geometry.size.width * Double(usage.documentBytes) / total
        let audioWidth = geometry.size.width * Double(usage.audioBytes) / total
        ZStack(alignment: .leading) {
          Capsule()
            .fill(.quaternary.opacity(0.5))
          HStack(spacing: usage.documentBytes > 0 && usage.audioBytes > 0 ? 2 : 0) {
            if usage.documentBytes > 0 {
              Rectangle()
                .fill(Color.accentColor)
                .frame(width: max(documentWidth, 3))
            }
            if usage.audioBytes > 0 {
              Rectangle()
                .fill(.orange)
                .frame(width: max(audioWidth, 3))
            }
          }
          .clipShape(Capsule())
        }
      }
      .frame(height: 10)

      HStack(spacing: 16) {
        legendEntry(color: Color.accentColor, label: "Notes and transcripts",
          value: formatted(usage.documentBytes))
        if usage.audioBytes > 0 {
          legendEntry(color: .orange, label: "Audio", value: formatted(usage.audioBytes))
        }
        Spacer()
        Text(formatted(usage.totalBytes) + " total")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func legendEntry(color: Color, label: String, value: String) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.weight(.medium))
    }
  }
}

private struct HookSettingsPane: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "Hooks",
          subtitle: "Run a command or send a web request when the finalized meeting archive changes."
        )

        Divider()

        Text("Command")
          .font(.headline)

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
          GridRow {
            Text("Run on")
              .gridColumnAlignment(.trailing)
            Picker("Run on", selection: $model.postMeetingHookLocation) {
              ForEach(
                RemoteSyncService.Configuration.HookLocation.allCases.filter {
                  model.remoteSyncEnabled || $0 != .remote
                }
              ) { location in
                Text(location.label).tag(location)
              }
            }
            .labelsHidden()
          }

          if model.postMeetingHookLocation != .disabled {
            GridRow {
              Text("Command")
                .gridColumnAlignment(.trailing)
              HStack(spacing: 8) {
                TextField("Command to run after archive changes", text: $model.postMeetingHookCommand)
                  .textFieldStyle(.roundedBorder)
                Button("Test", action: model.testPostMeetingHook)
                  .disabled(!model.canTestPostMeetingHook)
              }
            }
          }
        }
        .controlSize(.large)

        if model.postMeetingHookLocation != .disabled {
          Text("Runs inside the archive folder using a non-interactive shell. Use Test to verify that every required tool is available.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !model.hookSettingsStatusText.isEmpty {
          Text(model.hookSettingsStatusText)
            .font(.caption)
            .foregroundStyle(model.hookSettingsStatusText.contains("failed") ? .red : .secondary)
        }

        Divider()

        Text("Web request")
          .font(.headline)

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
          GridRow {
            Text("URL")
              .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
              TextField("https://example.com/meetings", text: $model.httpHookURLDraft)
                .textFieldStyle(.roundedBorder)
              Button("Test", action: model.testHTTPHook)
                .disabled(!model.canTestHTTPHook)
            }
          }

          if !model.httpHookURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GridRow {
              Text("Send")
                .gridColumnAlignment(.trailing)
              Picker("Send", selection: $model.httpHookPayload) {
                ForEach(RemoteSyncService.Configuration.HookPayload.allCases) { payload in
                  Text(payload.label).tag(payload)
                }
              }
              .labelsHidden()
              .fixedSize()
            }

            GridRow {
              Text("Headers")
                .gridColumnAlignment(.trailing)
              GrowingTextEditor(text: $model.httpHookHeadersDraft, minHeight: 72)
                .padding(2)
                .background(
                  Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
                }
            }
          }
        }
        .controlSize(.large)

        if !model.httpHookURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Sends the chosen Markdown file as the request body, with the meeting title, id, times, and folder as X-Meeting-Notes-… headers. Add one header per line to authenticate; your headers override the defaults.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !model.httpHookStatusText.isEmpty {
          Text(model.httpHookStatusText)
            .font(.caption)
            .foregroundStyle(model.httpHookStatusText.contains("failed") ? .red : .secondary)
        }

      }
      .padding(28)
    }
    .onAppear {
      // The persisted hook location can be stale when remote sync was turned
      // off while this pane was not visible (or by another settings path).
      if !model.remoteSyncEnabled, model.postMeetingHookLocation == .remote {
        model.postMeetingHookLocation = .disabled
        model.schedulePostMeetingHookSettingsSave()
      }
    }
    .onChange(of: model.postMeetingHookLocation, model.schedulePostMeetingHookSettingsSave)
    .onChange(of: model.postMeetingHookCommand, model.schedulePostMeetingHookSettingsSave)
    .onChange(of: model.httpHookURLDraft, model.scheduleHTTPHookSettingsSave)
    .onChange(of: model.httpHookHeadersDraft, model.scheduleHTTPHookSettingsSave)
    .onChange(of: model.httpHookPayload, model.scheduleHTTPHookSettingsSave)
  }
}

private struct TranscriptionsSettingsPane: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "Transcriptions",
          subtitle: "Configure transcript cleanup, retention, and source audio."
        )

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Remove filler words")
              .font(.body.weight(.medium))
            Text("Remove uh, um, er, hmm, and similar verbal pauses from transcripts.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Remove filler words", isOn: Binding(
            get: { model.removeFillerWords },
            set: { model.setRemoveFillerWords($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Keep audio recordings")
              .font(.body.weight(.medium))
            Text("Retain microphone and system audio and sync it to the archive.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Keep audio recordings", isOn: Binding(
            get: { model.keepAudioAfterProcessing },
            set: { model.setKeepAudioAfterProcessing($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        Label(
          "Off by default. When off, audio is deleted after successful processing.",
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Delete detailed records automatically")
              .font(.body.weight(.medium))
            Text("Remove word-for-word transcripts and retained audio after a set period.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Toggle("Delete detailed records automatically", isOn: Binding(
            get: { model.automaticTranscriptDeletionEnabled },
            set: { model.setAutomaticTranscriptDeletionEnabled($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        if model.automaticTranscriptDeletionEnabled {
          HStack {
            Text("Delete after")
            Spacer()
            Stepper(
              value: Binding(
                get: { model.transcriptRetentionDays },
                set: { model.setTranscriptRetentionDays($0) }),
              in: 1...3_650
            ) {
              Text("\(model.transcriptRetentionDays) days")
                .monospacedDigit()
                .frame(minWidth: 74, alignment: .trailing)
            }
          }
        }

        Label(
          "Structured meeting notes stay available. Deleted transcripts and audio cannot be recovered.",
          systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if !model.transcriptRetentionStatusText.isEmpty {
          Text(model.transcriptRetentionStatusText)
            .font(.caption)
            .foregroundStyle(
              model.transcriptRetentionStatusText.contains("failed") ? .red : .secondary)
        }
      }
      .padding(28)
    }
  }
}

private struct TanaSettingsPane: View {
  @Bindable var model: AppModel
  @State private var searchText = ""

  private var filteredSupertags: [TanaSupertagChoice] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.tanaSupertagChoices }
    return model.tanaSupertagChoices.filter {
      $0.name.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "Tana",
          subtitle: "Use selected parts of your Tana graph to improve names and terminology."
        )

        Divider()

        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Use Tana for enrichment")
              .font(.body.weight(.medium))
            Text("Off by default. Nothing is read until you connect and choose Supertags.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Use Tana for enrichment", isOn: Binding(
            get: { model.tanaEnabled },
            set: { model.setTanaEnabled($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        if model.tanaEnabled {
          Divider()

          HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 6) {
                Image(systemName: model.tanaConnected ? "checkmark.circle.fill" : "circle.dashed")
                  .foregroundStyle(model.tanaConnected ? .green : .secondary)
                Text(model.tanaConnected ? "Connected to Tana" : "Connect Tana")
                  .font(.body.weight(.medium))
              }
              Text("Authorization is handled by Tana Outliner and stored securely in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.tanaConnected {
              Button("Disconnect", action: model.disconnectTana)
                .disabled(model.tanaConnectionInProgress)
            } else {
              Button("Connect", action: model.connectTana)
                .buttonStyle(.borderedProminent)
                .disabled(model.tanaConnectionInProgress)
            }
          }

          if model.tanaConnected {
            Divider()

            Text("Graph")
              .font(.headline)

            HStack {
              Text("Workspace")
              Spacer()
              Picker("Workspace", selection: Binding(
                get: { model.tanaWorkspaceID },
                set: { model.selectTanaWorkspace($0) }
              )) {
                Text("Choose a workspace…").tag("")
                if !model.tanaWorkspaceID.isEmpty,
                  !model.tanaWorkspaces.contains(where: { $0.id == model.tanaWorkspaceID })
                {
                  Text("\(model.tanaWorkspaceName.isEmpty ? "Selected workspace" : model.tanaWorkspaceName) (not loaded)")
                    .tag(model.tanaWorkspaceID)
                }
                ForEach(model.tanaWorkspaces) { workspace in
                  Text(workspace.name).tag(workspace.id)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(maxWidth: 320, alignment: .trailing)
            }

            if !model.tanaWorkspaceID.isEmpty {
              Divider()

              VStack(alignment: .leading, spacing: 5) {
                Text("Supertags used for enrichment")
                  .font(.headline)
                Text("Choose only the entity types that contain useful names, such as people, projects, products, or teams.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }

              TextField("Search Supertags", text: $searchText)
                .textFieldStyle(.roundedBorder)

              if model.tanaSupertags.isEmpty {
                ContentUnavailableView(
                  "No Supertags found",
                  systemImage: "number",
                  description: Text("Open this workspace in Tana Outliner, then reconnect.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
              } else {
                ScrollView {
                  LazyVStack(spacing: 0) {
                    ForEach(filteredSupertags) { tag in
                      Button {
                        model.setTanaSupertag(
                          tag, selected: !model.isTanaSupertagSelected(tag))
                      } label: {
                        HStack(spacing: 10) {
                          Image(systemName: model.isTanaSupertagSelected(tag)
                            ? "checkmark.square.fill" : "square")
                            .foregroundStyle(model.isTanaSupertagSelected(tag)
                              ? Color.accentColor : .secondary)
                          Text(tag.name)
                            .foregroundStyle(.primary)
                          Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                      }
                      .buttonStyle(.plain)
                      Divider()
                    }
                  }
                }
                .frame(height: 240)
                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
              }
            }
          }

          if !model.tanaStatusText.isEmpty {
            Text(model.tanaStatusText)
              .font(.caption)
              .foregroundStyle(
                model.tanaStatusText.localizedCaseInsensitiveContains("failed") ? .red : .secondary)
          }

          Label(
            "Meeting Notes reads the selected entity names from the local Tana API only while Tana Outliner is open. It never changes your graph.",
            systemImage: "hand.raised"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(28)
    }
  }
}

private struct DictionarySettingsPane: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsPaneHeader(
        title: "Dictionary",
        subtitle: "Help Meeting Notes recognize names and specialist terminology."
      )

      Divider()

      Text("Add a term")
        .font(.headline)

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          Text("Term")
            .gridColumnAlignment(.trailing)
          TextField("Name or specialist term", text: $model.vocabularyTermDraft)
        }
        GridRow {
          Text("May sound like")
            .gridColumnAlignment(.trailing)
          TextField("Common mishearing (optional)", text: $model.vocabularyMishearingDraft)
            .onSubmit(model.addVocabularyEntry)
        }
      }
      .controlSize(.large)

      HStack {
        Text("Separate multiple alternatives with commas.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Add Term", action: model.addVocabularyEntry)
          .buttonStyle(.borderedProminent)
          .disabled(!model.canAddVocabularyEntry)
      }

      Divider()

      Text("Saved terms")
        .font(.headline)

      if model.vocabularyEntries.isEmpty {
        RecognitionEmptyState()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.vocabularyEntries) { entry in
              VocabularyRow(entry: entry) {
                model.removeVocabularyEntry(entry)
              }
              Divider()
            }
          }
        }
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
      }

      if !model.vocabularyStatusText.isEmpty {
        Text(model.vocabularyStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()
      Label(
        "Common mishearings are corrected after transcription.",
        systemImage: "info.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(28)
  }
}

private struct RecognitionEmptyState: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "text.book.closed")
        .font(.system(size: 27, weight: .light))
        .foregroundStyle(.tertiary)
      Text("No custom terms yet")
        .font(.body.weight(.medium))
      Text("Add names, product names, or specialist terms above.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
  }
}

private struct VocabularyRow: View {
  let entry: VocabularyEntry
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.term)
          .font(.body.weight(.medium))
        if !entry.aliases.isEmpty {
          Text("May sound like: \(entry.aliases.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Delete term")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }
}

private struct MicrophoneSettingsPane: View {
  @Bindable var model: AppModel
  @State private var draggedDeviceID: String?

  private var includedDevices: [MicrophoneDeviceChoice] {
    model.microphoneDevices.filter { !$0.isExcluded }
  }

  private var excludedDevices: [MicrophoneDeviceChoice] {
    model.microphoneDevices.filter(\.isExcluded)
  }

  private var currentDeviceID: String? {
    includedDevices.first(where: \.isConnected)?.id
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsPaneHeader(
          title: "Microphone",
          subtitle: "Choose which microphone Meeting Notes uses for your voice."
        )

        Divider()

        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Use System Default")
              .font(.body.weight(.medium))
            Text("Follow the microphone selected in macOS System Settings.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Toggle("Use System Default", isOn: Binding(
            get: { model.useSystemDefaultMicrophone },
            set: { model.setUseSystemDefaultMicrophone($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }

        if !model.useSystemDefaultMicrophone {
          Divider()

          VStack(alignment: .leading, spacing: 10) {
            Text("Microphone Priority")
              .font(.headline)
            Text("The first connected microphone in this list is used.")
              .font(.caption)
              .foregroundStyle(.secondary)

            if includedDevices.isEmpty {
              Text("No microphones available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
              VStack(spacing: 0) {
                ForEach(Array(includedDevices.enumerated()), id: \.element.id) { index, device in
                  MicrophoneDeviceRow(
                    device: device,
                    isCurrent: device.id == currentDeviceID,
                    canMoveUp: index > 0,
                    canMoveDown: index < includedDevices.count - 1,
                    moveUp: { model.moveMicrophone(device, by: -1) },
                    moveDown: { model.moveMicrophone(device, by: 1) },
                    exclude: { model.setMicrophoneExcluded(device, excluded: true) },
                    remove: { model.removeMicrophone(device) },
                    beginDragging: {
                      draggedDeviceID = device.id
                      return NSItemProvider(object: device.id as NSString)
                    }
                  )
                  .onDrop(
                    of: [UTType.text],
                    delegate: MicrophonePriorityDropDelegate(
                      targetID: device.id,
                      draggedDeviceID: $draggedDeviceID,
                      move: model.moveMicrophone(id:relativeTo:)
                    )
                  )
                  if index < includedDevices.count - 1 { Divider() }
                }
              }
              .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .onDrop(
                of: [UTType.text],
                delegate: MicrophonePriorityListDropDelegate(draggedDeviceID: $draggedDeviceID)
              )
            }
          }

          if !excludedDevices.isEmpty {
            Divider()
            Text("Excluded Devices")
              .font(.headline)
            VStack(spacing: 0) {
              ForEach(Array(excludedDevices.enumerated()), id: \.element.id) { index, device in
                HStack(spacing: 10) {
                  Image(systemName: "mic.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                  Text(device.name)
                    .foregroundStyle(device.isConnected ? .primary : .secondary)
                  Spacer()
                  if !device.isConnected {
                    Text("Disconnected")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Button("Restore") {
                    model.setMicrophoneExcluded(device, excluded: false)
                  }
                  .buttonStyle(.borderless)
                  if !device.isConnected {
                    Button("Forget", role: .destructive) {
                      model.removeMicrophone(device)
                    }
                    .buttonStyle(.borderless)
                  }
                }
                .padding(.vertical, 9)
                if index < excludedDevices.count - 1 { Divider() }
              }
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }
      .padding(28)
    }
    .onAppear(perform: model.refreshMicrophoneDevices)
  }
}

private struct MicrophoneDeviceRow: View {
  let device: MicrophoneDeviceChoice
  let isCurrent: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let moveUp: () -> Void
  let moveDown: () -> Void
  let exclude: () -> Void
  let remove: () -> Void
  let beginDragging: () -> NSItemProvider
  @State private var isHovered = false

  var body: some View {
    ZStack {
      Rectangle()
        .fill(isHovered ? Color.primary.opacity(0.05) : .clear)

      HStack(spacing: 10) {
        Image(systemName: "circle.grid.2x3.fill")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(width: 10)
          .opacity(isHovered ? 1 : 0)
        Image(systemName: device.isSystemDefault ? "laptopcomputer" : "mic")
          .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
          .frame(width: 18)
        Text(device.name)
          .foregroundStyle(device.isConnected ? .primary : .secondary)
        Spacer()
        if isCurrent {
          Text("Current")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
        } else if device.isSystemDefault {
          Text("macOS default")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !device.isConnected {
          Text("Disconnected")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        Menu {
          Button("Move Up", action: moveUp)
            .disabled(!canMoveUp)
          Button("Move Down", action: moveDown)
            .disabled(!canMoveDown)
          Divider()
          Button("Exclude", action: exclude)
          if !device.isConnected {
            Divider()
            Button("Forget Device", role: .destructive, action: remove)
          }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      .padding(.vertical, 9)
      .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onDrag(beginDragging)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .help("Drag to change microphone priority")
  }
}

private struct MicrophonePriorityDropDelegate: DropDelegate {
  let targetID: String
  @Binding var draggedDeviceID: String?
  let move: (String, String) -> Void

  func dropEntered(info: DropInfo) {
    guard let draggedDeviceID, draggedDeviceID != targetID else { return }
    withAnimation(.easeInOut(duration: 0.15)) {
      move(draggedDeviceID, targetID)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedDeviceID = nil
    return true
  }

  func dropExited(info: DropInfo) {}
}

/// Backstop for the whole priority list: whenever a drag session ends over the
/// container (including cancelled drags that never call the row delegates'
/// `performDrop`), clear the stale drag state so no dangling highlight remains.
private struct MicrophonePriorityListDropDelegate: DropDelegate {
  @Binding var draggedDeviceID: String?

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedDeviceID = nil
    return true
  }

  func dropExited(info: DropInfo) {
    // The drag left the list entirely; treat the session as cancelled.
    draggedDeviceID = nil
  }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    SettingsWindowHostView()
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

/// A plain-text editor that reports its full content height instead of
/// scrolling internally, so a settings pane shows one scrollbar rather than a
/// scroll view nested inside another scroll view.
private struct GrowingTextEditor: NSViewRepresentable {
  @Binding var text: String
  var minHeight: CGFloat = 120

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: GrowingTextEditor
    /// Height is measured with a private text stack. Measuring through the
    /// live text container would leave it sized for measurement rather than
    /// for the visible frame, and the editor would then draw over the
    /// controls below it.
    private let measuringStorage = NSTextStorage()
    private let measuringLayout = NSLayoutManager()
    private let measuringContainer = NSTextContainer()

    init(_ parent: GrowingTextEditor) {
      self.parent = parent
      super.init()
      measuringStorage.addLayoutManager(measuringLayout)
      measuringLayout.addTextContainer(measuringContainer)
      measuringContainer.lineFragmentPadding = 5
    }

    func measuredHeight(
      text: String, font: NSFont, width: CGFloat, insets: NSSize
    ) -> CGFloat {
      // A trailing newline has no glyphs, so pad it to keep the caret's line.
      let measured = text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text)
      measuringContainer.size = NSSize(
        width: max(1, width - insets.width * 2), height: .greatestFiniteMagnitude)
      measuringStorage.setAttributedString(
        NSAttributedString(string: measured, attributes: [.font: font]))
      measuringLayout.ensureLayout(for: measuringContainer)
      return measuringLayout.usedRect(for: measuringContainer).height + insets.height * 2
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = true
    textView.string = text
    return textView
  }

  func updateNSView(_ textView: NSTextView, context: Context) {
    context.coordinator.parent = self
    if textView.string != text { textView.string = text }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0,
      let font = textView.font
    else { return nil }
    let contentHeight = context.coordinator.measuredHeight(
      text: text, font: font, width: width, insets: textView.textContainerInset)
    return CGSize(width: width, height: max(minHeight, contentHeight.rounded(.up)))
  }
}

private final class SettingsWindowHostView: NSView {
  private weak var configuredWindow: NSWindow?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window, configuredWindow !== window else { return }
    configuredWindow = window
    window.styleMask.insert([.resizable, .fullSizeContentView])
    window.toolbar = nil
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.title = "Meeting Notes Settings"
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = false
    window.minSize = NSSize(width: 640, height: 480)
    // The user may make the window as large as their display allows.
    window.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    if ProcessInfo.processInfo.arguments.contains("--ui-test") {
      window.setContentSize(NSSize(width: 860, height: 640))
      window.center()
    } else {
      // Remember whatever size and position the user leaves behind. The first
      // launch after this change starts from a sensible default instead of the
      // older, more cramped frame.
      let autosaveName = "MeetingNotesSettingsWindow"
      let seededKey = "settingsWindowFrameSeeded"
      if !UserDefaults.standard.bool(forKey: seededKey) {
        UserDefaults.standard.set(true, forKey: seededKey)
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
      }
      window.setFrameAutosaveName(autosaveName)
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}
