import Foundation
import CryptoKit

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
  /// Pending consent must never transfer to a different signed-in session or server.
  public var pluginConsentScope: String? {
    guard let storedToken else { return nil }
    return SHA256.hash(data: Data("\(serverURL.absoluteString)|\(storedToken)".utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
  public func pluginRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
    if path.hasPrefix("/api/"), storedToken == nil { throw CloudAccountClientError.missingToken }
    return try await client.pluginRequest(path: path, method: method, body: body, token: storedToken)
  }
}
