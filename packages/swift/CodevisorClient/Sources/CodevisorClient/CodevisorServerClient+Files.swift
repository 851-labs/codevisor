import Foundation

extension CodevisorServerClient {
  public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
    let response = try await performRaw(
      Self.uploadPath(name: name),
      method: "POST",
      body: data,
      contentType: mimeType
    )
    return try decoder.decode(ServerFileMetadata.self, from: response)
  }

  public func uploadFile(name: String, mimeType: String, fileURL: URL) async throws -> ServerFileMetadata {
    let response = try await performUpload(
      Self.uploadPath(name: name),
      fileURL: fileURL,
      contentType: mimeType
    )
    return try decoder.decode(ServerFileMetadata.self, from: response)
  }

  private static func uploadPath(name: String) -> String {
    let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
    return "/v1/files?name=\(encodedName)"
  }

  public func filePreview(id: String) async throws -> Data {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await performRaw("/v1/files/\(encoded)?preview=1", method: "GET", body: nil, contentType: nil)
  }

  public func filePreview(path: String, sessionId: UUID?) async throws -> Data {
    var components = URLComponents()
    components.path = "/v1/fs/file"
    components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "preview", value: "1")]
    if let sessionId { components.queryItems?.append(URLQueryItem(name: "sessionId", value: sessionId.uuidString)) }
    guard let requestPath = components.string else { throw CodevisorServerClientError.invalidResponse }
    return try await performRaw(requestPath, method: "GET", body: nil, contentType: nil)
  }

  public func fileData(id: String) async throws -> Data {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try await performRaw("/v1/files/\(encoded)", method: "GET", body: nil, contentType: nil)
  }

  public func fileData(sessionId: UUID, path: String) async throws -> Data {
    let requestPath = try liveFileRequestPath(sessionId: sessionId, path: path)
    return try await performRaw(requestPath, method: "GET", body: nil, contentType: nil)
  }

  public func fileVersion(sessionId: UUID, path: String) async throws -> String? {
    let requestPath = try liveFileRequestPath(sessionId: sessionId, path: path)
    let (_, response) = try await performRawResponse(
      requestPath,
      method: "HEAD",
      body: nil,
      contentType: nil
    )
    return Self.fileVersion(of: response)
  }

  static func fileVersion(of response: HTTPURLResponse) -> String? {
    if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
      return etag
    }
    let fallback = [
      response.value(forHTTPHeaderField: "Last-Modified"),
      response.value(forHTTPHeaderField: "Content-Length"),
    ].compactMap { $0 }.joined(separator: ":")
    return fallback.isEmpty ? nil : fallback
  }

  func liveFileRequestPath(sessionId: UUID, path: String) throws -> String {
    var components = URLComponents()
    components.path = "/v1/fs/file"
    components.queryItems = [
      URLQueryItem(name: "path", value: path),
      URLQueryItem(name: "sessionId", value: sessionId.uuidString),
    ]
    guard let requestPath = components.string else {
      throw CodevisorServerClientError.invalidURL("fs/file")
    }
    return requestPath
  }
}
