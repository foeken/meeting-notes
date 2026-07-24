import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var uiTestWindow: NSWindow?
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let arguments = ProcessInfo.processInfo.arguments
    if let flag = arguments.firstIndex(of: "--regenerate-insights"),
      arguments.indices.contains(flag + 1)
    {
      let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
      let model = AppModel()
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
      let model = AppModel()
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
    guard ProcessInfo.processInfo.arguments.contains("--ui-test") else { return }
    NSApp.setActivationPolicy(.regular)
    let model = AppModel()
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
        width: showingSettings ? 860 : 350,
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
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(model: model)
    } label: {
      Image(systemName: menuBarIcon)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(model: model)
    }
    .defaultSize(width: 760, height: 540)
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
}
