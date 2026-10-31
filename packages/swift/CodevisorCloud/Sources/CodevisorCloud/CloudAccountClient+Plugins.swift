import Foundation

extension CloudAccountClienting {
  public func pluginRequest(path: String, method: String, body: Data?, token: String?) async throws -> Data {
    throw CloudAccountClientError.invalidResponse
  }
}

extension CloudAccountClient {
  public func pluginRequest(path: String, method: String, body: Data?, token: String?) async throws -> Data {
    try await perform(path, method: method, body: body, token: token).0
  }
}

extension CloudAccountController {
  public var hasPluginSession: Bool { storedToken != nil }

  public var pluginConsentAccount: String? {
    guard storedToken != nil, let userId else { return nil }
    return "\(serverURL.absoluteString)|\(userId)"
  }
  public func pluginRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
    if path.hasPrefix("/api/"), storedToken == nil { throw CloudAccountClientError.missingToken }
    return try await client.pluginRequest(path: path, method: method, body: body, token: storedToken)
  }
}
