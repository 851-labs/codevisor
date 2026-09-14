import Foundation

public struct CloudAppleChallenge: Codable, Sendable {
  public let id: String
  public let nonce: String

  public init(id: String, nonce: String) {
    self.id = id
    self.nonce = nonce
  }
}

public struct CloudAppleCredential: Encodable, Sendable {
  public let challengeId: String
  public let authorizationCode: String
  public let firstName: String?
  public let lastName: String?

  public init(challengeId: String, authorizationCode: String, firstName: String?, lastName: String?) {
    self.challengeId = challengeId
    self.authorizationCode = authorizationCode
    self.firstName = firstName
    self.lastName = lastName
  }
}

extension CloudAccountClient {
  public func linkedProviders(token: String) async throws -> Set<CloudSignInProvider> {
    struct Account: Decodable { let providerId: String }
    let (data, _) = try await perform("/api/auth/list-accounts", token: token)
    let accounts = try JSONDecoder().decode([Account].self, from: data)
    return Set(accounts.compactMap { CloudSignInProvider(rawValue: $0.providerId) })
  }

  public func startAppleSignIn(link: Bool, token: String?) async throws -> CloudAppleChallenge {
    let (data, _) = try await perform(
      "/api/auth/apple/native/start", method: "POST",
      body: JSONEncoder().encode(["link": link]), token: token)
    return try JSONDecoder().decode(CloudAppleChallenge.self, from: data)
  }

  public func completeAppleSignIn(_ credential: CloudAppleCredential, token: String?) async throws -> String {
    let (data, response) = try await perform(
      "/api/auth/apple/native/complete", method: "POST",
      body: JSONEncoder().encode(credential), token: token)
    return try Self.sessionToken(fromHeader: response, body: data)
  }
}
