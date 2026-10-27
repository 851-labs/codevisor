import CodevisorCore
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
struct PluginCatalogModelTests {
  @Test("Without a query the catalog shows Codevisor then Popular, and never registry results")
  func featuredSections() async {
    let model = PluginCatalogModel(client: Self.client(CatalogTransport()))

    await model.load()

    #expect(model.sections(hiding: []).map(\.title) == ["Codevisor", "Popular"])
    #expect(!model.isLoading)
  }

  @Test("A search waits for the debounce, then adds the MCP Registry section")
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
    #expect(model.sections(hiding: []).map(\.title) == ["Codevisor", "Popular", "MCP Registry"])
  }

  @Test("Blocked publishers disappear from Browse")
  func hidesBlockedPublishers() async {
    let model = PluginCatalogModel(client: Self.client(CatalogTransport()))
    await model.load()

    #expect(model.sections(hiding: ["popular-co"]).map(\.title) == ["Codevisor"])
  }

  @Test("Capability chips count each kind and skip the empty ones")
  func capabilityCounts() {
    let capabilities = ServerPluginCapabilities(
      tools: [.init(name: "a")],
      events: [.init(name: "e1"), .init(name: "e2")],
      panes: [.init(type: "p", title: "P", resourceUri: "ui://p")])

    #expect(PluginCapabilityCount.counts(in: capabilities).map(\.title) == ["1 tool", "2 events", "1 pane"])
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
    return (Data(Self.body(searching: query != nil).utf8), response)
  }

  private static func body(searching: Bool) -> String {
    let registry = searching ? "," + entry(id: "io.github.x/linear", source: "registry") : ""
    return #"{"entries":["# + entry(id: "grafana", source: "first-party") + ","
      + entry(id: "popular-co/linear", source: "popular") + registry + "]}"
  }

  private static func entry(id: String, source: String) -> String {
    """
    {"id":"\(id)","name":"\(id)","description":"","publisher":"p","version":"1","transport":"stdio",\
    "source":"\(source)","capabilities":{}}
    """
  }
}
