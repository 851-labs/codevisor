import CodevisorClient
import Foundation
import Network

/// Suggestions follow the workspace's authenticated proxy, just like page
/// requests. The ephemeral session has no website cookies or shared URL cache.
@MainActor
public final class BrowserSearchProvider {
  private var session: URLSession?
  private let client: any CodevisorServerClienting
  private let resolveBaseURL: @MainActor () async -> URL?

  public init(client: any CodevisorServerClienting, resolveBaseURL: @escaping @MainActor () async -> URL?) {
    self.client = client
    self.resolveBaseURL = resolveBaseURL
  }

  public func suggestions(_ query: String) async throws -> [String] {
    guard BrowserSuggestions.allowsRemoteSuggestions(query) else { return [] }
    if session == nil {
      let credential = try await client.browserProxySession()
      guard let endpoint = await resolveBaseURL(), let host = endpoint.host,
        ["http", "https"].contains(endpoint.scheme),
        let portNumber = UInt16(exactly: endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)),
        let port = NWEndpoint.Port(rawValue: portNumber)
      else { throw URLError(.notConnectedToInternet) }
      try Task.checkCancellation()
      var proxy = ProxyConfiguration(
        httpCONNECTProxy: .hostPort(host: .init(host), port: port),
        tlsOptions: endpoint.scheme == "https" ? NWProtocolTLS.Options() : nil)
      proxy.allowFailover = false
      proxy.applyCredential(username: credential.username, password: credential.password)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.proxyConfigurations = [proxy]
      configuration.httpCookieStorage = nil
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 5
      session = URLSession(configuration: configuration)
    }
    var url = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    url.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
    url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    do {
      let (data, response) = try await session!.data(from: url.url!)
      guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 128 * 1024,
        let result = try JSONSerialization.jsonObject(with: data) as? [Any], result.count > 1,
        result[0] as? String == query, let values = result[1] as? [String]
      else { return [] }
      return Array(values.prefix(8))
    } catch {
      if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled {
        session?.invalidateAndCancel()
        session = nil
      }
      throw error
    }
  }
}
