import Foundation

/// Public plugin metadata and moderation always come from Codevisor, independently
/// of the account's discovery server and the machine receiving an installation.
public struct PluginCatalogClient: Sendable {
  static let officialServerURL = URL(string: "https://cloud.codevisor.dev")!
  typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let baseURL: URL
  private let fetch: Fetch

  public init() {
    #if DEBUG
      let baseURL = CodevisorAppVariant.developmentCloud?.url ?? Self.officialServerURL
    #else
      let baseURL = Self.officialServerURL
    #endif
    let session = CloudAccountClient.makeCookieFreeSession()
    self.init(baseURL: baseURL, fetch: { try await session.data(for: $0) })
  }

  init(baseURL: URL = Self.officialServerURL, fetch: @escaping Fetch) {
    self.baseURL = baseURL
    self.fetch = fetch
  }

  public func index() async throws -> ServerPluginRegistryIndex {
    try await get("plugins/index.json")
  }

  public func entry(id: String) async throws -> ServerPluginRegistryEntry {
    guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
      id != ".", id != ".."
    else { throw PluginAccessError("This plugin link is invalid.") }
    return try await get("plugins/\(id).json")
  }

  public func policy() async throws -> PluginAccessPolicy {
    try await get("plugins/policy")
  }

  private func get<Value: Decodable>(_ path: String) async throws -> Value {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await fetch(request)
    guard let response = response as? HTTPURLResponse else { throw CloudAccountClientError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      throw CloudAccountClientError.httpStatus(response.statusCode)
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
