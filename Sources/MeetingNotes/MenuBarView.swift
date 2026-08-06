import AppKit
import SwiftUI

/// Tracks whether Option is held so a view can offer an alternate action.
/// The popover does not receive key events while it is open, so this observes
/// the modifier flags directly.
@MainActor
@Observable
final class OptionKeyMonitor {
  private(set) var isPressed = NSEvent.modifierFlags.contains(.option)
  @ObservationIgnored private var monitor: Any?

  func start() {
    guard monitor == nil else { return }
    isPressed = NSEvent.modifierFlags.contains(.option)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.isPressed = event.modifierFlags.contains(.option) }
      return event
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    isPressed = false
  }
}

struct MenuBarView: View {
  @Bindable var model: AppModel
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @State private var optionKey = OptionKeyMonitor()

  private static let todayTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        header
        Divider()
        VStack(alignment: .leading, spacing: 14) {
          if let app = model.detectedMeetingApp, model.state == .idle {
            meetingDetectionPanel(app: app)
          }

          meetingField

          if model.state == .paused {
            Label("Recording stays paused until you resume", systemImage: "pause.circle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(.orange)
          }

          if (model.state == .recording || model.state == .paused) && !model.recentTurns.isEmpty {
            transcriptPreview
          }

          if model.state != .recording && model.state != .paused {
            todayOverview
          }

          recoveryActions
          primaryActions
          statusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
      }
      .allowsHitTesting(model.meetingPendingDeletion == nil)

      if let meeting = model.meetingPendingDeletion {
        deletionConfirmation(for: meeting)
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
          .zIndex(1)
      }
    }
    .frame(width: 390)
    .background(.ultraThinMaterial)
    .animation(.easeOut(duration: 0.16), value: model.meetingPendingDeletion?.id)
    .onExitCommand(perform: model.cancelMeetingDeletion)
    .onAppear { optionKey.start() }
    .onDisappear { optionKey.stop() }
  }

  private func deletionConfirmation(for meeting: TodayMeetingSummary) -> some View {
    ZStack {
      Color.black.opacity(0.20)
        .contentShape(Rectangle())
        .onTapGesture(perform: model.cancelMeetingDeletion)

      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "trash")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.red)
            .frame(width: 34, height: 34)
            .background(Color.red.opacity(0.10), in: Circle())

          VStack(alignment: .leading, spacing: 3) {
            Text("Delete meeting?")
              .font(.headline.weight(.semibold))
            Text(meeting.title)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Text("Remove this meeting from this Mac and the synced archive? This can’t be undone.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Spacer()
          Button("Cancel", action: model.cancelMeetingDeletion)
            .buttonStyle(.bordered)
            .keyboardShortcut(.defaultAction)
          Button("Delete", role: .destructive, action: model.confirmMeetingDeletion)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .controlSize(.regular)
      }
      .padding(16)
      .frame(width: 340)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.primary.opacity(0.12), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
  }

  private func meetingDetectionPanel(app: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "video.badge.checkmark")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.tint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(app) meeting detected")
          .font(.caption.weight(.semibold))
        Text("Camera and microphone are active.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      Button("Not now", action: model.dismissDetectedMeeting)
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Record", action: model.recordDetectedMeeting)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
    .padding(10)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 1) {
        Text("Meeting Notes")
          .font(.headline.weight(.semibold))
        Text(model.archiveSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      HStack(spacing: 5) {
        Circle()
          .fill(stateColor)
          .frame(width: 7, height: 7)
        Text(stateLabel)
          .font(.caption.weight(.medium))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.primary.opacity(0.07), in: Capsule())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }

  private var meetingField: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text("MEETING")
          .font(.caption2.weight(.semibold))
          .tracking(0.8)
          .foregroundStyle(.secondary)
        Spacer()
        if model.state == .recording || model.state == .paused {
          Button {
            model.discussCurrentMeetingInCodex(startNewTask: optionKey.isPressed)
          } label: {
            ChatGPTActionButtonLabel(
              isLoading: model.codexLaunchingCurrentMeeting,
              isAlternate: optionKey.isPressed)
          }
          .buttonStyle(.plain)
          .disabled(model.codexLaunchingCurrentMeeting)
          .help(
            optionKey.isPressed
              ? "Start a new ChatGPT task for this meeting"
              : "Discuss this meeting with ChatGPT (hold Option for a new task)")
        }
      }
      HStack(spacing: 10) {
        Image(systemName: "text.cursor")
          .foregroundStyle(.secondary)
        TextField("Meeting title", text: $model.title)
          .textFieldStyle(.plain)
          .font(.body.weight(.semibold))
          .onSubmit { model.updateTitle() }
          .onChange(of: model.title) { model.updateTitle() }
        if model.state == .recording || model.state == .paused {
          Text(model.elapsed.meetingTimestamp)
            .font(.system(.body, design: .monospaced, weight: .semibold))
            .foregroundStyle(model.state == .paused ? .orange : .primary)
        }
      }
      .padding(.horizontal, 13)
      .frame(height: 44)
      .background(cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(.primary.opacity(0.11), lineWidth: 0.5)
      }
    }
  }

  private var transcriptPreview: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Live transcript", systemImage: "text.alignleft")
          .font(.caption.weight(.semibold))
        Spacer()
        if model.liveUsingOpenAI {
          Text("OPENAI")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
        } else {
          Text("LOCAL")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
          if model.canUpgradeLivePreview {
            Button("Upgrade") { model.upgradeLiveToOpenAI() }
              .buttonStyle(.plain)
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.tint)
              .help("Use the OpenAI live engine for the rest of this meeting")
          }
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 9)

      Divider().padding(.horizontal, 11)

      ForEach(Array(model.recentTurns.suffix(3).enumerated()), id: \.element.id) { index, turn in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(turn.start.meetingTimestamp)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
          Text(turn.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        if index < min(model.recentTurns.count, 3) - 1 {
          Divider().padding(.leading, 52)
        }
      }
    }
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var todayOverview: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        dayNavigationButton(
          systemImage: "chevron.left",
          accessibilityLabel: "Previous day",
          action: model.showPreviousMeetingDay)

        Image(systemName: "calendar")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Text(model.meetingDayTitle)
          .font(.caption.weight(.semibold))

        Spacer()

        Text("\(model.displayedMeetings.count) meeting\(model.displayedMeetings.count == 1 ? "" : "s")")
          .font(.caption2)
          .foregroundStyle(.secondary)

        dayNavigationButton(
          systemImage: "chevron.right",
          accessibilityLabel: "Next day",
          isDisabled: !model.canShowNextMeetingDay,
          action: model.showNextMeetingDay)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 10)

      Divider().padding(.horizontal, 10)

      if model.displayedMeetings.isEmpty {
        VStack(spacing: 5) {
          Image(systemName: "calendar.badge.clock")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.tertiary)
          Text(model.canShowNextMeetingDay ? "No completed meetings on this day." : "Completed meetings will appear here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
      } else if model.displayedMeetings.count > 4 {
        // Keep the popover usable for long days: show every meeting inside a
        // capped scroll area instead of truncating the list.
        ScrollView {
          VStack(spacing: 0) {
            meetingRows
          }
        }
        .frame(height: 264)
      } else {
        meetingRows
      }
    }
    .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.primary.opacity(0.07), lineWidth: 0.5)
    }
  }

  private var meetingRows: some View {
    ForEach(Array(model.displayedMeetings.enumerated()), id: \.element.id) {
      index, meeting in
      Group {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.todayTimeFormatter.string(from: meeting.startedAt))
                  .font(.system(.caption2, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .monospacedDigit()
                  .frame(width: 36, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 5) {
                    Text(meeting.title)
                      .font(.caption.weight(.semibold))
                      .lineLimit(1)
                  }
                  Text(meeting.summary ?? durationText(for: meeting))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              Spacer(minLength: 4)
              Button {
                model.discussMeetingInCodex(meeting, startNewTask: optionKey.isPressed)
              } label: {
                ChatGPTIconButtonLabel(
                  isLoading: model.codexLaunchingMeetingID == meeting.id,
                  isAlternate: optionKey.isPressed)
              }
              .buttonStyle(.plain)
              .disabled(
                !model.canReadMeetings || model.codexLaunchingMeetingID != nil
                  || model.isMeetingFinalizing(meeting) || model.isMeetingRecoverable(meeting)
              )
              .help(
                optionKey.isPressed
                  ? "Start a new ChatGPT task for this meeting"
                  : "Discuss with ChatGPT (hold Option for a new task)")
              Menu {
                if model.isMeetingFinalizing(meeting) {
                  Button("Finalizing…", systemImage: "waveform") {}
                    .disabled(true)
                  Divider()
                  Button(role: .destructive) {
                    model.requestMeetingDeletion(meeting)
                  } label: {
                    Label("Delete meeting…", systemImage: "trash")
                  }
                  .disabled(!model.canManageMeetings)
                } else if model.isMeetingRecoverable(meeting) {
                  Button {
                    model.recoverMeeting(meeting)
                  } label: {
                    Label("Retry finalization", systemImage: "arrow.counterclockwise")
                  }
                  .disabled(!model.canManageMeetings)
                  Divider()
                  Button(role: .destructive) {
                    model.requestMeetingDeletion(meeting)
                  } label: {
                    Label("Delete meeting…", systemImage: "trash")
                  }
                  .disabled(!model.canManageMeetings)
                } else {
                  Button {
                    model.requestMeetingRename(meeting)
                  } label: {
                    Label("Rename…", systemImage: "pencil")
                  }
                  .disabled(!model.canManageMeetings)
                  Divider()
                  if meeting.summary != nil {
                    Button {
                      model.openMeetingSummary(meeting)
                    } label: {
                      Label("Open summary", systemImage: "doc.text")
                    }
                  }
                  Button {
                    model.openMeetingTranscript(meeting)
                  } label: {
                    Label("Open transcript", systemImage: "text.quote")
                  }
                  Divider()
                  Button {
                    model.recreateMeetingNotes(meeting)
                  } label: {
                    Label(
                      meeting.summary == nil ? "Create summary" : "Recreate summary",
                      systemImage: meeting.summary == nil ? "sparkles" : "arrow.clockwise")
                  }
                  .disabled(!model.canManageMeetings)
                  Divider()
                  Button(role: .destructive) {
                    model.requestMeetingDeletion(meeting)
                  } label: {
                    Label("Delete meeting…", systemImage: "trash")
                  }
                  .disabled(!model.canManageMeetings)
                }
              } label: {
                Image(systemName: "ellipsis")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .frame(width: 22, height: 18)
                  .contentShape(Rectangle())
              }
              .menuIndicator(.hidden)
              .menuStyle(.borderlessButton)
              .fixedSize()
              // Read-only actions (open files, discuss) stay reachable while
              // a stopped capture is processed; mutating items above disable
              // themselves individually.
              .disabled(!model.canReadMeetings)
              .accessibilityLabel("More actions")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            if model.meetingPendingRename?.id == meeting.id {
              Divider().padding(.leading, 62)
              VStack(alignment: .leading, spacing: 8) {
                Text("Rename meeting")
                  .font(.caption.weight(.semibold))
                TextField("Meeting title", text: $model.meetingRenameDraft)
                  .textFieldStyle(.roundedBorder)
                  .onSubmit(model.confirmMeetingRename)
                HStack {
                  Spacer()
                  Button("Cancel", action: model.cancelMeetingRename)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                  Button("Rename", action: model.confirmMeetingRename)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.canConfirmMeetingRename)
                }
              }
              .padding(.leading, 62)
              .padding(.trailing, 11)
              .padding(.vertical, 9)
              .background(Color.accentColor.opacity(0.045))
            }

          }
        if index < model.displayedMeetings.count - 1 {
          Divider().padding(.leading, 62)
        }
      }
    }
  }

  private func dayNavigationButton(
    systemImage: String,
    accessibilityLabel: String,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.caption2.weight(.semibold))
        .frame(width: 22, height: 22)
        .background(.primary.opacity(isDisabled ? 0.025 : 0.06), in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .accessibilityLabel(accessibilityLabel)
  }

  private func durationText(for meeting: TodayMeetingSummary) -> String {
    if model.isMeetingFinalizing(meeting) { return "Finalizing…" }
    if model.isMeetingRecoverable(meeting) { return "Finalization interrupted · audio retained" }
    guard let endedAt = meeting.endedAt else { return "Transcript saved" }
    let minutes = max(1, Int(endedAt.timeIntervalSince(meeting.startedAt) / 60))
    return "\(minutes) min · Transcript saved"
  }

  @ViewBuilder private var recoveryActions: some View {
    if model.recoverableMeetingAvailable || model.enrichmentRetryAvailable {
      HStack(spacing: 8) {
        if model.recoverableMeetingAvailable {
          Button("Recover capture", systemImage: "arrow.counterclockwise", action: model.recoverLatestMeeting)
            .disabled(!model.canManageMeetings)
        }
        if model.enrichmentRetryAvailable {
          Button("Retry notes", systemImage: "sparkles", action: model.retryEnrichment)
            .disabled(!model.canManageMeetings)
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var primaryActions: some View {
    HStack(spacing: 8) {
      if model.state == .recording || model.state == .paused {
        Button(action: model.togglePause) {
          Label(
            model.state == .paused ? "Resume" : "Pause",
            systemImage: model.state == .paused ? "play.fill" : "pause.fill")
            .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }

      Button(action: model.toggleRecording) {
        Label(buttonTitle, systemImage: buttonIcon)
          .font(.body.weight(.medium))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 34)
          .background(recordButtonGradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .stroke(.white.opacity(0.22), lineWidth: 0.5)
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(model.state == .starting || model.state == .processing ? 0.55 : 1)
      .disabled(model.state == .starting || model.state == .processing)

      Menu {
        Button {
          NSApp.activate(ignoringOtherApps: true)
          openSettings()
        } label: {
          Label("Settings…", systemImage: "gearshape")
        }
        Button {
          (NSApp.delegate as? AppDelegate)?.checkForUpdates()
        } label: {
          Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        Divider()
        Button("Quit Meeting Notes", systemImage: "power") { NSApplication.shared.terminate(nil) }
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(0.08))
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(.primary.opacity(0.18), lineWidth: 0.75)
          Image(systemName: "ellipsis")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
      }
      .menuIndicator(.hidden)
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("More actions")
    }
  }

  private var statusLine: some View {
    Group {
      if model.statusText != "Ready" {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: statusIcon)
            .font(.caption2)
          Text(model.statusText)
            .font(.caption)
            .textSelection(.enabled)
            .lineLimit(2)
          Spacer(minLength: 0)
        }
        .foregroundStyle(statusColor)
      }
    }
  }

  private var buttonTitle: String {
    switch model.state {
    case .recording, .paused: "Stop"
    case .starting: "Starting…"
    case .processing: "Processing…"
    default: "Record"
    }
  }

  private var buttonIcon: String {
    model.state == .recording || model.state == .paused ? "stop.fill" : "record.circle"
  }

  private var statusColor: Color {
    if case .failed = model.state { return .red }
    switch model.statusSeverity {
    case .error: return .red
    case .warning: return .orange
    case .info: return .secondary
    }
  }

  private var statusIcon: String {
    if case .failed = model.state { return "exclamationmark.triangle.fill" }
    // A reported problem outranks the capture state, so the icon and the red
    // or orange status text never disagree.
    switch model.statusSeverity {
    case .error: return "exclamationmark.triangle.fill"
    case .warning: return "exclamationmark.circle"
    case .info: break
    }
    switch model.state {
    case .recording: return "waveform"
    case .paused: return "pause.fill"
    case .processing, .starting: return "ellipsis"
    case .idle, .failed: return "checkmark.circle.fill"
    }
  }

  private var stateLabel: String {
    switch model.state {
    case .idle: return "Ready"
    case .starting: return "Starting"
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .processing: return "Processing"
    case .failed: return "Needs attention"
    }
  }

  private var stateColor: Color {
    switch model.state {
    case .idle: return .green
    case .starting, .processing: return .blue
    case .recording: return .red
    case .paused: return .orange
    case .failed: return .red
    }
  }

  private var cardFill: Color {
    Color(nsColor: .controlBackgroundColor).opacity(0.58)
  }

  private var recordButtonGradient: LinearGradient {
    let colors: [Color] =
      model.state == .recording || model.state == .paused
      ? [Color(red: 1.0, green: 0.30, blue: 0.34), Color(red: 0.82, green: 0.10, blue: 0.18)]
      : [Color(red: 0.20, green: 0.55, blue: 1.0), Color(red: 0.06, green: 0.33, blue: 0.92)]
    return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
  }
}
