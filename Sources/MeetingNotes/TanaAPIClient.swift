import Foundation

actor TanaAPIClient {
  static let shared = TanaAPIClient()
  private static let baseURL = URL(string: "http://127.0.0.1:8262")!
  private static let searchPageSize = 1000
  private static let searchResultCap = 20000

  /// True when the most recent `enrichmentEntities` call could not retrieve
  /// every node (result cap reached or the API ignored pagination offsets).
  private(set) var lastEnrichmentTruncated = false

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
    lastEnrichmentTruncated = false
    var names = Set<String>()
    for tagID in settings.selectedSupertagIDs.sorted() {
      let entities = try await allNodes(tagID: tagID, workspaceID: workspaceID)
      for entity in entities {
        let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { names.insert(name) }
      }
    }
    return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// Fetches every node for a Supertag by paging with `limit`/`offset`. Some
  /// server builds ignore `offset`; a repeated page is detected and treated as
  /// the end of pagination with `lastEnrichmentTruncated` set so callers can
  /// surface the partial result.
  private func allNodes(tagID: String, workspaceID: String) async throws -> [Entity] {
    var collected: [Entity] = []
    var seenIDs = Set<String>()
    var offset = 0
    while collected.count < Self.searchResultCap {
      let page: [Entity] = try await get(path: "nodes/search", queryItems: [
        URLQueryItem(name: "query[hasType][typeId]", value: tagID),
        URLQueryItem(name: "query[hasType][includeExtensions]", value: "true"),
        URLQueryItem(name: "query[inWorkspace]", value: workspaceID),
        URLQueryItem(name: "workspaceIds[0]", value: workspaceID),
        URLQueryItem(name: "limit", value: String(Self.searchPageSize)),
        URLQueryItem(name: "offset", value: String(offset)),
      ])
      let fresh = page.filter { seenIDs.insert($0.id).inserted }
      if !page.isEmpty, fresh.isEmpty {
        // The API returned a page we already have: offset is unsupported and
        // anything beyond the first page is unreachable.
        lastEnrichmentTruncated = true
        break
      }
      collected.append(contentsOf: fresh)
      if page.count < Self.searchPageSize { return collected }
      offset += page.count
    }
    if collected.count >= Self.searchResultCap { lastEnrichmentTruncated = true }
    return collected
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
