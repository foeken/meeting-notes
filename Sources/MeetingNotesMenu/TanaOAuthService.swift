import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

@MainActor
final class TanaOAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = TanaOAuthService()

  enum AuthError: LocalizedError {
    case unavailable
    case notConnected
    case invalidMetadata
    case registrationFailed
    case invalidCallback
    case stateMismatch
    case tokenExchangeFailed(String)

    var errorDescription: String? {
      switch self {
      case .unavailable: "Open Tana Outliner on this Mac, then try again."
      case .notConnected: "Connect Tana in Settings before using Tana enrichment."
      case .invalidMetadata: "Tana returned invalid OAuth configuration."
      case .registrationFailed: "Meeting Notes could not register with Tana."
      case .invalidCallback: "Tana sign-in did not return a valid authorization code."
      case .stateMismatch: "Tana sign-in could not be verified. Please try again."
      case .tokenExchangeFailed(let detail):
        detail.isEmpty ? "Tana sign-in failed." : "Tana sign-in failed: \(detail)"
      }
    }
  }

  private struct AuthorizationMetadata: Decodable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL

    enum CodingKeys: String, CodingKey {
      case authorizationEndpoint = "authorization_endpoint"
      case tokenEndpoint = "token_endpoint"
      case registrationEndpoint = "registration_endpoint"
    }
  }

  private struct RegistrationResponse: Decodable {
    let clientID: String

    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
  }

  private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }

  private struct StoredTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
  }

  private let baseURL = URL(string: "http://127.0.0.1:8262")!
  private let redirectURI = "meetingnotesmenu://oauth/tana"
  private let resource = "http://127.0.0.1:8262/mcp"
  private let clientIDKey = "tanaOAuthClientID"
  private let keychainService = "app.meetingnotes.menu.tana"
  private var webSession: ASWebAuthenticationSession?

  var isConnected: Bool { loadTokens() != nil }

  func signIn() async throws {
    guard await TanaAPIClient.healthCheck() else { throw AuthError.unavailable }
    let metadata = try await authorizationMetadata()
    let clientID = try await registeredClientID(using: metadata.registrationEndpoint)
    let verifier = Self.randomURLSafeString(byteCount: 32)
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    let state = Self.randomURLSafeString(byteCount: 24)

    var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "resource", value: resource),
    ]
    guard let authorizationURL = components.url else { throw AuthError.invalidMetadata }
    let callback = try await authorize(at: authorizationURL)
    guard let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
      callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state
    else { throw AuthError.stateMismatch }
    guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
      !code.isEmpty
    else { throw AuthError.invalidCallback }

    let response = try await tokenRequest(
      endpoint: metadata.tokenEndpoint,
      fields: [
        "grant_type": "authorization_code",
        "code": code,
        "client_id": clientID,
        "redirect_uri": redirectURI,
        "code_verifier": verifier,
        "resource": resource,
      ])
    saveTokens(response)
  }

  func signOut() {
    deleteTokens()
  }

  func validAccessToken() async throws -> String {
    guard let stored = loadTokens() else { throw AuthError.notConnected }
    if let expiresAt = stored.expiresAt, expiresAt.timeIntervalSinceNow < 60 {
      guard let refreshToken = stored.refreshToken else {
        deleteTokens()
        throw AuthError.notConnected
      }
      let metadata = try await authorizationMetadata()
      guard let clientID = UserDefaults.standard.string(forKey: clientIDKey) else {
        deleteTokens()
        throw AuthError.notConnected
      }
      let response = try await tokenRequest(
        endpoint: metadata.tokenEndpoint,
        fields: [
          "grant_type": "refresh_token",
          "refresh_token": refreshToken,
          "client_id": clientID,
          "resource": resource,
        ])
      saveTokens(response, preservingRefreshToken: refreshToken)
      return response.accessToken
    }
    return stored.accessToken
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
  }

  private func authorize(at url: URL) async throws -> URL {
    defer { webSession = nil }
    return try await withCheckedThrowingContinuation { continuation in
      // AuthenticationServices completes on a private Safari XPC queue. An unannotated
      // closure created in this @MainActor type inherits main-actor isolation and traps
      // at runtime when Safari invokes it. Keep this callback explicitly queue-independent.
      let completion: @Sendable (URL?, (any Error)?) -> Void = { callback, error in
        if let error { continuation.resume(throwing: error) }
        else if let callback { continuation.resume(returning: callback) }
        else { continuation.resume(throwing: AuthError.invalidCallback) }
      }
      let session = ASWebAuthenticationSession(
        url: url, callbackURLScheme: "meetingnotesmenu", completionHandler: completion)
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      webSession = session
      guard session.start() else {
        webSession = nil
        continuation.resume(throwing: AuthError.invalidCallback)
        return
      }
    }
  }

  private func authorizationMetadata() async throws -> AuthorizationMetadata {
    let url = baseURL.appending(path: ".well-known/oauth-authorization-server")
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let metadata = try? JSONDecoder().decode(AuthorizationMetadata.self, from: data)
    else { throw AuthError.invalidMetadata }
    return metadata
  }

  private func registeredClientID(using endpoint: URL) async throws -> String {
    if let existing = UserDefaults.standard.string(forKey: clientIDKey), !existing.isEmpty {
      return existing
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client_name": "Meeting Notes",
      "redirect_uris": [redirectURI],
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"],
      "token_endpoint_auth_method": "none",
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 300,
      let registration = try? JSONDecoder().decode(RegistrationResponse.self, from: data)
    else { throw AuthError.registrationFailed }
    UserDefaults.standard.set(registration.clientID, forKey: clientIDKey)
    return registration.clientID
  }

  private func tokenRequest(endpoint: URL, fields: [String: String]) async throws -> TokenResponse {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var components = URLComponents()
    components.queryItems = fields.sorted(by: { $0.key < $1.key }).map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 500
    guard status < 300, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        .flatMap { ($0["error_description"] ?? $0["error"]) as? String } ?? ""
      throw AuthError.tokenExchangeFailed(detail)
    }
    return token
  }

  private func saveTokens(_ response: TokenResponse, preservingRefreshToken: String? = nil) {
    let stored = StoredTokens(
      accessToken: response.accessToken,
      refreshToken: response.refreshToken ?? preservingRefreshToken,
      expiresAt: response.expiresIn.map { Date().addingTimeInterval($0) })
    guard let data = try? JSONEncoder().encode(stored) else { return }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "oauth",
    ]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  private func loadTokens() -> StoredTokens? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "oauth",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(StoredTokens.self, from: data)
  }

  private func deleteTokens() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: "oauth",
    ]
    SecItemDelete(query as CFDictionary)
  }

  private static func randomURLSafeString(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URL(Data(bytes))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
