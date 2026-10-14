import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCloud

@Suite("Presence-driven roster refresh")
@MainActor
struct CloudPresenceRosterTests {
  @Test("An unknown machine in a presence push triggers a roster refresh")
  func unknownMachineRefreshes() async {
    let m1 = testMachine("m1")
    let (controller, client, _) = await makeSignedIn(machines: [m1])
    let restCallsBefore = client.machineTokens.count

    let m2 = testMachine("m2", name: "MacBook Pro")
    client.machinesResult = .success([m1, m2])
    controller.reconcilePresence(with: [m1, m2])

    await controller.presenceRefreshTask?.value
    #expect(controller.machines.contains { $0.deviceId == "m2" })
    #expect(client.machineTokens.count == restCallsBefore + 1)
  }

  @Test("An online-state flip triggers a refresh; an identical view does not")
  func onlineFlipRefreshesIdenticalDoesNot() async {
    let online = testMachine("m1", online: true)
    let (controller, client, _) = await makeSignedIn(machines: [online])
    let restCallsBefore = client.machineTokens.count

    controller.reconcilePresence(with: [online])
    #expect(controller.presenceRefreshTask == nil)
    #expect(client.machineTokens.count == restCallsBefore)

    let offline = testMachine("m1", online: false)
    client.machinesResult = .success([offline])
    controller.reconcilePresence(with: [offline])
    await controller.presenceRefreshTask?.value
    #expect(controller.machines.first?.online == false)
    #expect(client.machineTokens.count == restCallsBefore + 1)
  }

  @Test("A new tunnel address triggers a refresh even while the machine stays online")
  func tunnelAddressChangeRefreshes() async {
    let before = testMachine("m1")
    let (controller, client, _) = await makeSignedIn(machines: [before])
    let restCallsBefore = client.machineTokens.count

    var after = before
    after.tunnel = CloudTunnelInfo(endpointId: "new-endpoint")
    client.machinesResult = .success([after])
    controller.reconcilePresence(with: [after])
    await controller.presenceRefreshTask?.value
    #expect(controller.machines.first?.tunnel?.endpointId == "new-endpoint")
    #expect(client.machineTokens.count == restCallsBefore + 1)
  }

  @Test("A presence burst coalesces into one refresh")
  func burstsCoalesce() async {
    let m1 = testMachine("m1")
    let (controller, client, _) = await makeSignedIn(machines: [m1])
    let restCallsBefore = client.machineTokens.count

    let m2 = testMachine("m2")
    let m3 = testMachine("m3")
    client.machinesResult = .success([m1, m2, m3])
    controller.reconcilePresence(with: [m1, m2])
    controller.reconcilePresence(with: [m1, m2, m3])

    await controller.presenceRefreshTask?.value
    #expect(controller.machines.count == 3)
    #expect(client.machineTokens.count == restCallsBefore + 1)
  }

  @Test("Presence pushes are ignored while signed out")
  func signedOutIgnoresPresence() async {
    let (controller, client, _) = makeController()
    let restCallsBefore = client.machineTokens.count

    controller.reconcilePresence(with: [testMachine("m1")])
    #expect(controller.presenceRefreshTask == nil)
    #expect(client.machineTokens.count == restCallsBefore)
    #expect(controller.machines.isEmpty)
  }
}
