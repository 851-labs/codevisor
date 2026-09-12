import Foundation
import Testing
@testable import CodevisorCore

@Suite("Official plugin service")
struct PluginCatalogClientTests {
  @Test("Catalog, links, and policy use Codevisor without account credentials or cached policy")
  func publicRequests() async throws {
    let entry = """
      {"id":"sample.notes","name":"Notes","version":"1.0.0","panes":[],
       "repo":"sample/notes","stars":0,"pushedAt":"2026-01-01T00:00:00Z","ageRating":4}
      """
    let client = PluginCatalogClient { request in
      let url = try #require(request.url)
      #expect(url.scheme == "https")
      #expect(url.host == "cloud.codevisor.dev")
      #expect(request.httpMethod == "GET")
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
      let responses = [
        "/plugins/index.json": "{\"entries\":[\(entry)]}",
        "/plugins/sample.notes.json": entry,
        "/plugins/policy": """
        {"supportedAgeRating":16,"blocks":[
          {"targetKind":"plugin","target":"sample.notes","reason":"reviewed"}
        ],"ageRatings":[{"pluginId":"sample.notes","minimumAge":18}]}
        """,
      ]
      let body = try #require(responses[url.path])
      return (
        Data(body.utf8),
        try #require(
          HTTPURLResponse(
            url: url, statusCode: 200,
            httpVersion: nil, headerFields: nil))
      )
    }

    #expect(try await client.index().entries.map(\.id) == ["sample.notes"])
    #expect(try await client.entry(id: "sample.notes").ageRating == 4)
    let policy = try await client.policy()
    #expect(policy.restriction(pluginId: "sample.notes", ageRating: 4, blockedPublishers: []) != nil)
    #expect(policy.ageRating(pluginId: "sample.notes", declared: 4) == 18)
    #expect(policy.ageRating(pluginId: "other.plugin", declared: 9) == 9)
    #expect(policy.ageRating(pluginId: "other.plugin", declared: nil) == nil)
  }

  @Test("A service error cannot provide a permissive policy", arguments: [403, 500])
  func rejectsHTTPFailure(status: Int) async throws {
    let client = PluginCatalogClient { request in
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: status,
          httpVersion: nil, headerFields: nil))
      return (Data("{\"supportedAgeRating\":16,\"blocks\":[],\"ageRatings\":[]}".utf8), response)
    }
    await #expect(throws: CloudAccountClientError.httpStatus(status)) { try await client.policy() }
  }

  @Test("Malformed and unavailable policy fail closed")
  func rejectsInvalidPolicy() async throws {
    let invalid = PluginCatalogClient { request in
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: 200,
          httpVersion: nil, headerFields: nil))
      return (Data("{}".utf8), response)
    }
    await #expect(throws: DecodingError.self) { try await invalid.policy() }
    let offline = PluginCatalogClient { _ in throw URLError(.notConnectedToInternet) }
    await #expect(throws: URLError.self) { try await offline.policy() }
  }

  @Test("Plugin links cannot change the public endpoint", arguments: ["", "../policy", "https://other.invalid", ".."])
  func rejectsInvalidID(id: String) async throws {
    let client = PluginCatalogClient { _ in
      Issue.record("An invalid link must not make a network request")
      throw CloudAccountClientError.invalidResponse
    }
    await #expect(throws: PluginAccessError.self) { try await client.entry(id: id) }
  }
}
