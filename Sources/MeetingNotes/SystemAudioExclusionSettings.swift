import Foundation
import ScreenCaptureKit

struct ExcludedAudioApp: Identifiable, Equatable, Sendable, Codable {
  var id: String { bundleIdentifier }
  let bundleIdentifier: String
  var name: String
}

/// Apps to drop from the system-audio channel via `SCContentFilter`'s
/// `excludingApplications`. Exists because ScreenCaptureKit's system-audio
/// capture is app-level, not device-level: it grabs any running app's audio
/// output regardless of which device that app targets, so a virtual-mic tool
/// (Audio Hijack, Loopback, etc.) routing processed mic audio to a virtual
/// output device still gets swept into "system audio" even when the actual
/// system output device is correctly set to real speakers.
enum SystemAudioExclusionStore {
  private static let key = "systemAudio.excludedApps"

  static func excludedApps(from defaults: UserDefaults = .standard) -> [ExcludedAudioApp] {
    guard let data = defaults.data(forKey: key),
      let stored = try? JSONDecoder().decode([ExcludedAudioApp].self, from: data)
    else { return [] }
    return stored
  }

  static func save(_ apps: [ExcludedAudioApp], to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(apps) {
      defaults.set(data, forKey: key)
    }
  }

  static func excludedBundleIdentifiers(from defaults: UserDefaults = .standard) -> Set<String> {
    Set(excludedApps(from: defaults).map(\.bundleIdentifier))
  }
}

/// Apps currently visible to ScreenCaptureKit, for the exclusion picker in
/// Settings. Requires the same Screen Recording permission system-audio
/// capture already needs; returns an empty list rather than throwing if that
/// permission isn't granted yet.
enum SystemAudioAppProvider {
  static func runningApps() async -> [ExcludedAudioApp] {
    guard
      let content = try? await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
    else { return [] }
    var seen = Set<String>()
    return content.applications.compactMap { app in
      guard !app.bundleIdentifier.isEmpty, seen.insert(app.bundleIdentifier).inserted else {
        return nil
      }
      return ExcludedAudioApp(bundleIdentifier: app.bundleIdentifier, name: app.applicationName)
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}
