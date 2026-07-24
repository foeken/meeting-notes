import Foundation

actor TanaAPIClient {
  static let shared = TanaAPIClient()
  private static let baseURL = URL(string: "http://127.0.0.1:8262")!

  struct Entity: Decodable, Equatable, Sendable {
    let id: String
    let name: String
  }

  enum APIError: LocalizedError {
    case unavailable
    case requestFailed(String)

    var errorDescription: String? {
      switch self {
      case .unavailable: "Open Tana Outliner on this Mac, then try again."
      case .requestFailed(let detail): "Tana could not be loaded: \(detail)"
      }
    }
  }

  static func healthCheck() async -> Bool {
    var request = URLRequest(url: baseURL.appending(path: "health"))
    request.timeoutInterval = 2
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
  }

  func workspaces() async throws -> [TanaWorkspace] {
    try await get(path: "workspaces")
  }

  func supertags(workspaceID: String) async throws -> [TanaSupertag] {
    try await get(path: "workspaces/\(workspaceID)/tags", queryItems: [
      URLQueryItem(name: "limit", value: "5000")
    ])
  }

  func enrichmentEntities(settings: TanaSettings) async throws -> [String] {
    guard settings.enabled, let workspaceID = settings.workspaceID,
      !settings.selectedSupertagIDs.isEmpty
    else { return [] }
    var names = Set<String>()
    for tagID in settings.selectedSupertagIDs.sorted() {
      let entities: [Entity] = try await get(path: "nodes/search", queryItems: [
        URLQueryItem(name: "query[hasType][typeId]", value: tagID),
        URLQueryItem(name: "query[hasType][includeExtensions]", value: "true"),
        URLQueryItem(name: "query[inWorkspace]", value: workspaceID),
        URLQueryItem(name: "workspaceIds[0]", value: workspaceID),
        URLQueryItem(name: "limit", value: "1000"),
      ])
      for entity in entities {
        let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { names.insert(name) }
      }
    }
    return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private func get<T: Decodable>(
    path: String, queryItems: [URLQueryItem] = []
  ) async throws -> T {
    guard await Self.healthCheck() else { throw APIError.unavailable }
    let token = try await TanaOAuthService.shared.validAccessToken()
    var components = URLComponents(
      url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else { throw APIError.requestFailed("Invalid URL") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 500
    guard status < 300 else {
      let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
      throw APIError.requestFailed(message)
    }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw APIError.requestFailed(error.localizedDescription) }
  }
}
