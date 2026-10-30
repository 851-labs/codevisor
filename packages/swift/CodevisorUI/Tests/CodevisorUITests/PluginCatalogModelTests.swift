import CodevisorCore
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
struct PluginCatalogModelTests {
  @Test("Without a query the catalog lists first-party then curated plugins in one list")
  func listsCatalog() async {
    let model = PluginCatalogModel(client: Self.client(CatalogTransport()))

    await model.load()

    #expect(model.visibleEntries(hiding: []).map(\.id) == ["codevisor/tools", "popular-co/linear"])
    #expect(!model.isLoading)
  }

  @Test("A search waits for the debounce and drops registry results an older server still sends")
  func debouncedSearch() async throws {
    let transport = CatalogTransport()
    let gate = SleepGate()
    let model = PluginCatalogModel(client: Self.client(transport), sleep: gate.sleep)
    await model.load()

    model.search("linear")
    await gate.waitForSleeper()
    #expect(transport.queries == [nil])

    gate.release()
    await model.settleSearch()

    #expect(transport.queries == [nil, "linear"])
    #expect(model.visibleEntries(hiding: []).map(\.id) == ["codevisor/tools", "popular-co/linear"])
  }

  @Test("Blocked publishers disappear from Browse")
  func hidesBlockedPublishers() async {
    let model = PluginCatalogModel(client: Self.client(CatalogTransport()))
    await model.load()

    #expect(model.visibleEntries(hiding: ["popular-co"]).map(\.id) == ["codevisor/tools"])
  }

  private static func client(_ transport: CatalogTransport) -> CodevisorServerClient {
    CodevisorServerClient(config: CodevisorServerConfig(requestTransport: transport))
  }
}

private final class SleepGate: Sendable {
  private struct State {
    var parked = 0
    var released = false
    var sleepers: [CheckedContinuation<Void, Never>] = []
    var watchers: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var sleep: PluginCatalogModel.Sleep {
    { [self] _ in await self.park() }
  }

  func waitForSleeper() async {
    await withCheckedContinuation { watcher in
      let parked = state.withLock { state in
        if state.parked == 0 { state.watchers.append(watcher) }
        return state.parked > 0
      }
      if parked { watcher.resume() }
    }
  }

  func release() {
    let sleepers = state.withLock { state in
      state.released = true
      defer { state.sleepers = [] }
      return state.sleepers
    }
    for sleeper in sleepers { sleeper.resume() }
  }

  private func park() async {
    await withCheckedContinuation { sleeper in
      let (resumeNow, watchers) = state.withLock { state in
        state.parked += 1
        defer { state.watchers = [] }
        if !state.released { state.sleepers.append(sleeper) }
        return (state.released, state.watchers)
      }
      for watcher in watchers { watcher.resume() }
      if resumeNow { sleeper.resume() }
    }
  }
}

private final class CatalogTransport: ServerRequestTransport, Sendable {
  private let recorded = Mutex<[String?]>([])
  var queries: [String?] { recorded.withLock { $0 } }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
    recorded.withLock { $0.append(query) }
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
    return (Data(body(searching: query != nil).utf8), response)
  }

  private func body(searching: Bool) -> String {
    let firstParty = [Self.entry(id: "codevisor/tools", source: "first-party")]
    let registry = searching ? [Self.entry(id: "io.github.x/linear", source: "registry")] : []
    let entries = firstParty + [Self.entry(id: "popular-co/linear", source: "popular")] + registry
    return #"{"entries":["# + entries.joined(separator: ",") + "]}"
  }

  private static func entry(id: String, source: String) -> String {
    """
    {"id":"\(id)","name":"\(id)","description":"","publisher":"p","version":"1","transport":"stdio",\
    "source":"\(source)","capabilities":{}}
    """
  }
}
