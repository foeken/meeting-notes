import Foundation

struct TanaWorkspace: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let homeNodeId: String?
}

struct TanaSupertag: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let color: String?
}

struct TanaSupertagChoice: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let tagIDs: Set<String>

  static func grouped(_ tags: [TanaSupertag]) -> [TanaSupertagChoice] {
    let grouped = Dictionary(grouping: tags) { tag in
      tag.name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    return grouped.compactMap { normalizedName, matches in
      guard !normalizedName.isEmpty,
        let displayName = matches
          .map({ $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
          .filter({ !$0.isEmpty })
          .sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
          .first
      else { return nil }
      return TanaSupertagChoice(
        id: normalizedName,
        name: displayName,
        tagIDs: Set(matches.map(\.id)))
    }
    .sorted {
      let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
      return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
  }
}

struct TanaSettings: Codable, Equatable, Sendable {
  var enabled: Bool
  var workspaceID: String?
  var workspaceName: String?
  var selectedSupertagIDs: Set<String>

  static let defaults = TanaSettings(
    enabled: false,
    workspaceID: nil,
    workspaceName: nil,
    selectedSupertagIDs: []
  )
}

enum TanaSettingsStore {
  private static let key = "tanaSettings"

  static func load(from defaults: UserDefaults = .standard) -> TanaSettings {
    guard let data = defaults.data(forKey: key),
      let settings = try? JSONDecoder().decode(TanaSettings.self, from: data)
    else { return .defaults }
    return settings
  }

  static func save(_ settings: TanaSettings, to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: key)
  }
}
