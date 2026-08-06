import AppKit
import SwiftUI

enum LiveTranscriptOverlaySettingsStore {
  private static let key = "liveTranscript.overlay"

  static func load(from defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: key)
  }

  static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: key)
  }
}

/// A slim borderless ticker above the Dock showing the current live sentence,
/// like subtitles. Shown while recording when the overlay setting is on.
@MainActor
final class LiveTranscriptOverlay {
  private let model: AppModel
  private var panel: NSPanel?

  init(model: AppModel) {
    self.model = model
    observe()
  }

  /// Re-evaluates visibility whenever the recording state or the setting
  /// changes. Observation tracking fires once per change, so re-arm each time.
  private func observe() {
    withObservationTracking {
      _ = model.state
      _ = model.liveTranscriptOverlayEnabled
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.update()
        self.observe()
      }
    }
    update()
  }

  private func update() {
    let recording = model.state == .recording || model.state == .paused
    if recording && model.liveTranscriptOverlayEnabled {
      show()
    } else {
      panel?.orderOut(nil)
      panel = nil
    }
  }

  private func show() {
    if panel != nil { return }
    let width: CGFloat = 760
    let height: CGFloat = 44
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.contentView = NSHostingView(rootView: LiveTranscriptTicker(model: model))
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(
        x: frame.midX - width / 2,
        y: frame.minY + 12))
    }
    panel.orderFrontRegardless()
    self.panel = panel
  }
}

private struct LiveTranscriptTicker: View {
  @Bindable var model: AppModel

  private var text: String {
    model.recentTurns.last?.text ?? "Listening…"
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "waveform")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
      Circle()
        .fill(model.state == .paused ? Color.orange : Color.red)
        .frame(width: 8, height: 8)
      Text(text)
        .font(.system(size: 15))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .frame(width: 760, height: 44)
    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
