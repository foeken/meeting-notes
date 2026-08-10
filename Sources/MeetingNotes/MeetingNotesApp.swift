import AppKit
import Sparkle
import SwiftUI

/// Tells Sparkle which appcast channels this Mac may install from. Read on
/// every check, so switching the setting takes effect without a relaunch.
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    UpdateChannelSettingsStore.load().allowedChannelNames
  }

  /// Beta testers read a separate feed that also carries every stable
  /// release. Returning `nil` keeps the bundle's own `SUFeedURL`.
  func feedURLString(for updater: SPUUpdater) -> String? {
    let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    return UpdateChannelSettingsStore.load().feedURLString(configuredFeed: configured)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Single app-wide model. The @main scene reuses this instance so CLI and
  /// UI-test modes never run a second set of live services.
  static let sharedModel = AppModel()

  private var uiTestWindow: NSWindow?
  private var liveTranscriptOverlay: LiveTranscriptOverlay?
  /// Sparkle holds its delegate weakly, so this must stay owned here.
  private let updaterDelegate = UpdateChannelDelegate()
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: updaterDelegate,
    userDriverDelegate: nil
  )

  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }

  private static let welcomeShownKey = "welcomeShown"

  /// Menu-bar-only apps are easy to lose on first launch, especially when the
  /// icon lands behind the MacBook notch. Shown once, on the first real launch.
  private func showWelcomeIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.welcomeShownKey) else { return }
    defaults.set(true, forKey: Self.welcomeShownKey)

    let alert = NSAlert()
    alert.messageText = "Meeting Notes lives in your menu bar"
    alert.informativeText = """
      Look for the waveform icon at the top of your screen and click it to \
      start recording.

      Don't see it? On a MacBook the icon can hide behind the notch when the \
      menu bar is full. Quit a few other menu-bar apps to make room and it \
      will appear.
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = ProcessInfo.processInfo.arguments
    if let flag = arguments.firstIndex(of: "--regenerate-insights"),
      arguments.indices.contains(flag + 1)
    {
      let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
      let model = Self.sharedModel
      Task { @MainActor in
        do {
          try await model.regenerateMeetingInsights(at: folder)
          FileHandle.standardOutput.write(Data("Meeting insights regenerated and synced.\n".utf8))
        } catch {
          FileHandle.standardError.write(
            Data("Insights regeneration failed: \(error.localizedDescription)\n".utf8))
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let flag = arguments.firstIndex(of: "--repair-meeting"), arguments.indices.contains(flag + 1) {
      let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
      let model = Self.sharedModel
      Task { @MainActor in
        do {
          try await model.repairCompletedMeeting(at: folder)
          FileHandle.standardOutput.write(Data("Meeting transcript repaired and synced.\n".utf8))
        } catch {
          FileHandle.standardError.write(Data("Repair failed: \(error.localizedDescription)\n".utf8))
        }
        NSApp.terminate(nil)
      }
      return
    }
    guard ProcessInfo.processInfo.arguments.contains("--ui-test") else {
      showWelcomeIfNeeded()
      liveTranscriptOverlay = LiveTranscriptOverlay(model: Self.sharedModel)
      // The lazy updater only exists once something touches it. Without this,
      // scheduled background update checks never started for users who never
      // clicked "Check for Updates…" — they stayed on old builds forever.
      _ = updaterController
      return
    }
    NSApp.setActivationPolicy(.regular)
    let model = Self.sharedModel
    if ProcessInfo.processInfo.arguments.contains("--ui-test-paused") {
      model.state = .paused
      model.elapsed = 3_725
      model.statusText = "Paused after sleep — press Resume"
      model.recentTurns = [
        TranscriptTurn(
          start: 3_690, end: 3_696, speaker: "Unknown",
          text: "We agreed to ship the migration in two phases.", source: .system),
        TranscriptTurn(
          start: 3_702, end: 3_707, speaker: "Unknown",
          text: "I will send the rollout plan tomorrow.", source: .microphone),
      ]
    } else if ProcessInfo.processInfo.arguments.contains("--ui-test-error") {
      model.state = .failed("System audio permission is required")
      model.statusText = "System audio permission is required"
      model.recoverableMeetingAvailable = true
      model.enrichmentRetryAvailable = true
    } else {
      let now = Date()
      model.displayedMeetings = [
        TodayMeetingSummary(
          id: UUID(), title: "Project Atlas review",
          startedAt: now.addingTimeInterval(-5_400),
          endedAt: now.addingTimeInterval(-3_900),
          summary: "Sequenced the security portfolio and agreed the validation needed before scaling investment."
        ),
        TodayMeetingSummary(
          id: UUID(), title: "Product check-in",
          startedAt: now.addingTimeInterval(-10_800),
          endedAt: now.addingTimeInterval(-9_900),
          summary: nil
        ),
      ]
    }
    if ProcessInfo.processInfo.arguments.contains("--ui-test-delete"),
      let meeting = model.displayedMeetings.first
    {
      model.meetingPendingDeletion = meeting
    }
    let showingSettings = ProcessInfo.processInfo.arguments.contains("--ui-test-settings")
    let window = NSWindow(
      contentRect: NSRect(
        x: 0, y: 0,
        width: showingSettings ? 860 : 390,
        height: showingSettings ? 640 : 460),
      styleMask: showingSettings
        ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable],
      backing: .buffered, defer: false
    )
    window.title = showingSettings ? "Meeting Notes Settings UI Test" : "Meeting Notes UI Test"
    if showingSettings {
      window.contentView = NSHostingView(rootView: SettingsView(model: model))
    } else {
      window.contentView = NSHostingView(rootView: MenuBarView(model: model))
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    uiTestWindow = window
  }
}

@main
struct MeetingNotesApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppDelegate.sharedModel

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      Image(systemName: menuBarIcon)
        .accessibilityLabel(menuBarAccessibilityLabel)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
    .defaultSize(width: 860, height: 640)
    .windowResizability(.contentMinSize)
  }

  private var menuBarIcon: String {
    switch model.state {
    case .recording: "waveform.and.mic"
    case .paused: "pause.fill"
    case .processing: "waveform"
    case .starting: "ellipsis"
    case .failed: "exclamationmark.triangle.fill"
    case .idle: "waveform"
    }
  }

  private var menuBarAccessibilityLabel: String {
    switch model.state {
    case .recording: "Meeting Notes, recording"
    case .paused: "Meeting Notes, paused"
    case .processing: "Meeting Notes, processing"
    case .starting: "Meeting Notes, starting"
    case .failed: "Meeting Notes, needs attention"
    case .idle: "Meeting Notes, ready"
    }
  }
}
