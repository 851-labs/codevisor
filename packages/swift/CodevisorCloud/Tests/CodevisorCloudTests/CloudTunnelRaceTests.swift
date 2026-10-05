import CodevisorNet
import CodevisorTestSupport
import ConcurrencyExtras
import Foundation
import Testing

@testable import CodevisorCloud

@MainActor
struct CloudTunnelRaceTests {
  @Test("Shutdown invalidates a reconfiguration suspended on the previous bind")
  func shutdownDuringReconfigure() async {
    await withMainSerialExecutor {
      let binds = TestSignal()
      let release = TestSignal()
      let endpoint = CloudTunnelEndpoint(
        credentialStore: InMemoryCloudCredentialStore(),
        bindEndpoint: { _ in
          binds.signal()
          if binds.value == 1 { await release.wait() }
          throw URLError(.cancelled)
        })
      await endpoint.configure(.init(relays: [], enabled: true))
      await binds.wait()
      let replacing = Task { await endpoint.configure(.init(relays: [.init(url: "https://new.test")], enabled: true)) }
      let stopping = Task { await endpoint.shutdown() }
      let releasing = Task { release.signal() }
      await releasing.value
      await stopping.value
      await replacing.value
      // Wait for any late binding attempt to settle through normal teardown.
      await endpoint.configure(.init(relays: [], enabled: false))
      #expect(binds.value == 1)
    }
  }

  @Test("A failed bind is retried by the next caller, not left down until the relay map changes")
  func failedBindRetries() async {
    let binds = TestSignal()
    let endpoint = CloudTunnelEndpoint(
      credentialStore: InMemoryCloudCredentialStore(),
      bindEndpoint: { _ in
        binds.signal()
        throw URLError(.notConnectedToInternet)
      })
    await endpoint.configure(.init(relays: [], enabled: true))
    #expect(await endpoint.endpoint() == nil)
    #expect(binds.value == 2)
    #expect(await endpoint.endpoint() == nil)
    #expect(binds.value == 3)
  }

  @Test("Rebuilding binds the same config afresh; with the tunnel off it binds nothing")
  func rebuild() async {
    let binds = TestSignal()
    let relays = LockIsolated<[[String]]>([])
    let endpoint = CloudTunnelEndpoint(
      credentialStore: InMemoryCloudCredentialStore(),
      bindEndpoint: { config in
        relays.withValue { $0.append(config.relays.map(\.url)) }
        binds.signal()
        throw URLError(.cannotConnectToHost)
      })
    await endpoint.rebuild()
    await endpoint.configure(.init(relays: [.init(url: "https://relay.test")], enabled: true))
    await binds.wait(for: 1)
    await endpoint.rebuild()
    await binds.wait(for: 2)
    await endpoint.configure(.init(relays: [], enabled: false))
    await endpoint.rebuild()
    await endpoint.shutdown()
    #expect(relays.value == [["https://relay.test"], ["https://relay.test"]])
  }
}
