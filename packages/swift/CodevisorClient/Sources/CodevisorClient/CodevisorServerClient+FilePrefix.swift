import Foundation

extension CodevisorServerClient {
  public func filePrefix(id: String, length: Int) async throws -> Data {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await performPrefixRequest("/v1/files/\(encoded)", length: length)
  }

  public func filePrefix(sessionId: UUID, path: String, length: Int) async throws -> Data {
    try await performPrefixRequest(liveFileRequestPath(sessionId: sessionId, path: path), length: length)
  }

  private func performPrefixRequest(_ path: String, length: Int) async throws -> Data {
    do {
      let headers = ["Range": "bytes=0-\(max(0, length - 1))"]
      return try await performRawResponse(path, method: "GET", body: nil, contentType: nil, headers: headers).0
    } catch CodevisorServerClientError.httpStatus(Self.rangeNotSatisfiableStatus, _) {
      return Data()
    }
  }

  private static let rangeNotSatisfiableStatus = 416
}
