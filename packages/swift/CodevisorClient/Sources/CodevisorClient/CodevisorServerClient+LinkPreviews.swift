import Foundation

public struct ServerLinkPreview: Codable, Equatable, Sendable {
  public struct Image: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let color: String

    public init(width: Double, height: Double, color: String) {
      self.width = width
      self.height = height
      self.color = color
    }
  }

  public let url: URL
  public let title: String?
  public let description: String?
  public let siteName: String?
  public let image: Image?

  public init(url: URL, title: String?, description: String?, siteName: String?, image: Image?) {
    self.url = url
    self.title = title
    self.description = description
    self.siteName = siteName
    self.image = image
  }
}

extension CodevisorServerClient {
  public func linkPreview(url: URL) async throws -> ServerLinkPreview {
    try await get(try linkPreviewPath("/v1/link-previews", url))
  }

  public func linkPreviewImage(url: URL) async throws -> Data {
    try await performRaw(
      try linkPreviewPath("/v1/link-previews/image", url), method: "GET", body: nil, contentType: nil)
  }

  private func linkPreviewPath(_ endpoint: String, _ url: URL) throws -> String {
    var components = URLComponents()
    components.path = endpoint
    components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
    guard let value = components.string else { throw CodevisorServerClientError.invalidURL(endpoint) }
    return value
  }
}

extension CodevisorServerClienting {
  public func linkPreview(url: URL) async throws -> ServerLinkPreview {
    throw CodevisorServerClientError.invalidResponse
  }

  public func linkPreviewImage(url: URL) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }
}
