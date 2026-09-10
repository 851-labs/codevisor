import CodevisorClient
import CodevisorProtocol
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
struct CloudMachineKeyLookupTests {
  private func fixture() -> (CloudAccountController, FakeCloudClient, CountingCredentialStore) {
    let store = CountingCredentialStore(base: InMemoryCloudCredentialStore(token: "token"))
    let client = FakeCloudClient()
    client.sessions["token"] = CloudSessionUser(userId: "user", email: nil)
    client.verifyResult = .success("token")
    client.machinesResult = .success([testMachine("machine")])
    let controller = CloudAccountController(
      clientFactory: { _ in client }, credentialStore: store, environmentCloud: nil,
      directPaths: CloudDirectPathController(credentialStore: store, prober: { _, _, _ in nil }),
      presenceSleep: TestClock().sleep
    )
    return (controller, client, store)
  }

  @Test("Repeated UI key lookups and roster refreshes do not reread storage")
  func repeatedLookups() async {
    let (controller, _, store) = fixture()
    await controller.bootstrap()
    defer { controller.signOut() }
    #expect(controller.isCloudSignedIn)
    #expect(store.pinCounts.reads == 1)
    let writes = store.pinCounts.writes
    for _ in 0..<100 {
      #expect(controller.verifiedMachineKey(for: testMachine("machine")) == "pk_machine")
      #expect(controller.verifiedMachineKey(for: testMachine("unknown")) == nil)
    }
    await controller.refreshMachines()
    #expect(store.pinCounts.reads == 1)
    #expect(store.pinCounts.writes == writes)
    #expect(store.pinCounts.mainThreadReads == 0)
  }

  @Test("Cached keys still reject a changed key until its explicit trust is persisted")
  func changedKey() async {
    let (controller, client, store) = fixture()
    await controller.bootstrap()
    defer { controller.signOut() }
    let swapped = testMachine("machine", publicKey: "replacement")
    client.machinesResult = .success([swapped])
    await controller.refreshMachines()
    #expect(controller.machinesWithChangedKeys == ["machine"])
    #expect(controller.verifiedMachineKey(for: swapped) == nil)
    #expect(await !controller.recoverLoopbackBridge(for: swapped))
    store.pinWriteError = CloudCredentialError(operation: "write", status: -1)
    controller.trustChangedMachineKey(deviceId: "machine")
    #expect(controller.verifiedMachineKey(for: swapped) == nil)
    #expect(controller.machinesWithChangedKeys == ["machine"])
    store.pinWriteError = nil
    controller.trustChangedMachineKey(deviceId: "machine")
    #expect(controller.verifiedMachineKey(for: swapped) == "replacement")
    #expect(controller.machinesWithChangedKeys.isEmpty)
    #expect(store.pinCounts.reads == 1)
  }

  @Test("Unreadable pins cannot be replaced by first-sight trust")
  func unreadablePins() async {
    let (controller, _, store) = fixture()
    store.pinReadError = CloudCredentialError(operation: "read", status: -1)
    await controller.bootstrap()
    defer { controller.signOut() }
    #expect(controller.machines.isEmpty)
    #expect(controller.verifiedMachineKey(for: testMachine("machine")) == nil)
    #expect(store.pinCounts.writes == 0)
    store.pinReadError = nil
    await controller.refreshMachines()
    #expect(controller.verifiedMachineKey(for: testMachine("machine")) == "pk_machine")
  }

  @Test("Signing back in reloads the persisted pins and preserves key continuity")
  func signInAgain() async {
    let (controller, client, store) = fixture()
    await controller.bootstrap()
    controller.signOut()
    #expect(controller.verifiedMachineKey(for: testMachine("machine")) == nil)
    let swapped = testMachine("machine", publicKey: "replacement")
    client.machinesResult = .success([swapped])
    await controller.completeSignIn(ott: "ott")
    defer { controller.signOut() }
    #expect(controller.machinesWithChangedKeys == ["machine"])
    #expect(controller.verifiedMachineKey(for: swapped) == nil)
    #expect(store.pinCounts.reads == 2)
  }
}
