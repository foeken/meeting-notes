import Foundation

/// Which published feed this Mac installs updates from.
///
/// Two mechanisms are used together, and they agree with each other:
///
/// 1. The channel selects its own appcast. Stable releases are written to
///    *both* feeds, so a beta tester still receives every stable release and
///    is never stranded on an ageing test build.
/// 2. Beta-only entries additionally carry `<sparkle:channel>beta</…>`, so a
///    stable updater would still refuse them even if the feeds were ever
///    merged. Sparkle always allows the default channel, so `.stable`
///    publishes an empty set rather than an explicit list.
enum UpdateChannel: String, CaseIterable, Codable, Identifiable, Sendable {
  case stable
  case beta

  /// The name published in the appcast for opt-in builds. Sparkle allows
  /// letters, numbers, dashes, underscores, and periods in channel names.
  static let betaChannelName = "beta"

  /// The beta feed sits beside the stable one, so it is derived from whatever
  /// `SUFeedURL` the build shipped with instead of being hard-coded twice.
  static let stableFeedFileName = "appcast.xml"
  static let betaFeedFileName = "appcast-beta.xml"

  var id: Self { self }

  var label: String {
    switch self {
    case .stable: "Stable"
    case .beta: "Beta"
    }
  }

  var explanation: String {
    switch self {
    case .stable: "Only released versions."
    case .beta: "Test builds first, plus every stable release."
    }
  }

  /// The channels Sparkle may look in. Empty means the default channel only;
  /// beta additionally opts into the tagged feed entries.
  var allowedChannelNames: Set<String> {
    switch self {
    case .stable: []
    case .beta: [Self.betaChannelName]
    }
  }

  /// Rewrites the bundle's configured feed to this channel's feed. Returns
  /// `nil` for stable, which tells Sparkle to keep using `SUFeedURL` as-is,
  /// and also whenever the configured feed is missing or unrecognised, so a
  /// malformed build falls back to its shipped feed instead of a guess.
  func feedURLString(configuredFeed: String?) -> String? {
    guard self == .beta else { return nil }
    guard let configuredFeed,
      let url = URL(string: configuredFeed),
      url.lastPathComponent == Self.stableFeedFileName
    else { return nil }
    return url.deletingLastPathComponent()
      .appendingPathComponent(Self.betaFeedFileName).absoluteString
  }
}

enum UpdateChannelSettingsStore {
  private static let key = "updates.channel"

  /// Unset, or a value written by a newer build, both fall back to stable so a
  /// Mac is never silently moved onto test builds.
  static func load(from defaults: UserDefaults = .standard) -> UpdateChannel {
    guard let raw = defaults.string(forKey: key), let channel = UpdateChannel(rawValue: raw) else {
      return .stable
    }
    return channel
  }

  static func save(_ channel: UpdateChannel, to defaults: UserDefaults = .standard) {
    defaults.set(channel.rawValue, forKey: key)
  }
}
