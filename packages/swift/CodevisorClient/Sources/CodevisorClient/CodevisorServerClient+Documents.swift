import Foundation

public struct ServerFileDocument: Codable, Equatable, Sendable {
  public let path: String
  public let content: String?
  public let version: String
  public let size: Int
  public let writable: Bool
  public let reason: String?

  public init(path: String, content: String?, version: String, size: Int, writable: Bool, reason: String? = nil) {
    self.path = path; self.content = content; self.version = version
    self.size = size; self.writable = writable; self.reason = reason
  }
}

public struct ServerFileEntry: Decodable, Identifiable, Equatable, Sendable {
  public var id: String { path }
  public let name: String
  public let path: String
  public let isDirectory: Bool
  public let isSymbolicLink: Bool
}

public struct ServerFileListing: Decodable, Sendable {
  public let path: String
  public let entries: [ServerFileEntry]
}

public struct ServerFileSearch: Decodable, Sendable {
  public let path: String
  public let entries: [ServerFileEntry]
  public let truncated: Bool
  public let skippedDirectories: Int
}

extension CodevisorServerClient {
  public func readDocument(path: String) async throws -> ServerFileDocument {
    try await get(fileRequestPath("/v1/fs/document", path: path))
  }

  public func saveDocument(path: String, content: String, version: String) async throws -> ServerFileDocument {
    struct Body: Encodable { let content: String; let version: String }
    return try await send(
      fileRequestPath("/v1/fs/document", path: path), method: "PUT", body: Body(content: content, version: version))
  }

  public func fileEntries(path: String, showHidden: Bool) async throws -> ServerFileListing {
    try await get(fileRequestPath("/v1/fs/entries", path: path) + "&showHidden=\(showHidden)")
  }

  public func searchFileEntries(path: String, query: String) async throws -> ServerFileSearch {
    var components = URLComponents(string: try fileRequestPath("/v1/fs/search", path: path))!
    components.queryItems?.append(URLQueryItem(name: "query", value: query))
    guard let endpoint = components.string else { throw CodevisorServerClientError.invalidURL(path) }
    return try await get(endpoint)
  }

  public func documentData(path: String) async throws -> Data {
    try await performRaw(fileRequestPath("/v1/fs/file", path: path), method: "GET", body: nil, contentType: nil)
  }

  private func fileRequestPath(_ endpoint: String, path: String) throws -> String {
    var components = URLComponents()
    components.path = endpoint
    components.queryItems = [URLQueryItem(name: "path", value: path)]
    guard let value = components.string else { throw CodevisorServerClientError.invalidURL(endpoint) }
    return value
  }
}

extension CodevisorServerClienting {
  public func readDocument(path: String) async throws -> ServerFileDocument {
    throw CodevisorServerClientError.invalidResponse
  }
  public func saveDocument(path: String, content: String, version: String) async throws -> ServerFileDocument {
    throw CodevisorServerClientError.invalidResponse
  }
  public func fileEntries(path: String, showHidden: Bool) async throws -> ServerFileListing {
    throw CodevisorServerClientError.invalidResponse
  }
  public func searchFileEntries(path: String, query: String) async throws -> ServerFileSearch {
    throw CodevisorServerClientError.invalidResponse
  }
  public func documentData(path: String) async throws -> Data { throw CodevisorServerClientError.invalidResponse }
}
