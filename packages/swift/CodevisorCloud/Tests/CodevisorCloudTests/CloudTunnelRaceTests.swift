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
}
