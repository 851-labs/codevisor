import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCloud

/// Presence pushed by the hub must keep the UI roster live: a machine signed
/// in on another device appears without waiting for the next foreground or a
/// settings screen's poll. The push is only a trigger — the REST fetch stays
/// the single writer of `machines`.
@Suite("Presence-driven roster refresh")
@MainActor
struct CloudPresenceRosterTests {
    @Test("An unknown machine in a presence push triggers a roster refresh")
    func unknownMachineRefreshes() async {
        let m1 = testMachine("m1")
        let (controller, client, _) = await makeSignedIn(machines: [m1])
        let restCallsBefore = client.machineTokens.count

        // The MacBook signs in elsewhere: the hub pushes it before any poll.
        let m2 = testMachine("m2", name: "MacBook Pro")
        client.machinesResult = .success([m1, m2])
        controller.reconcilePresence(with: [m1, m2])

        #expect(
            await waitUntil {
                await MainActor.run { controller.machines.contains { $0.deviceId == "m2" } }
            }
        )
        #expect(client.machineTokens.count == restCallsBefore + 1)
    }

    @Test("An online-state flip triggers a refresh; an identical view does not")
    func onlineFlipRefreshesIdenticalDoesNot() async {
        let online = testMachine("m1", online: true)
        let (controller, client, _) = await makeSignedIn(machines: [online])
        let restCallsBefore = client.machineTokens.count

        // Identical transport view: no fetch.
        controller.reconcilePresence(with: [online])
        try? await Task.sleep(for: .milliseconds(400))
        #expect(client.machineTokens.count == restCallsBefore)

        // The machine drops: the flip disagrees with the roster and refreshes.
        let offline = testMachine("m1", online: false)
        client.machinesResult = .success([offline])
        controller.reconcilePresence(with: [offline])
        #expect(
            await waitUntil {
                await MainActor.run { controller.machines.first?.online == false }
            }
        )
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

        #expect(
            await waitUntil {
                await MainActor.run { controller.machines.count == 3 }
            }
        )
        #expect(client.machineTokens.count == restCallsBefore + 1)
    }

    @Test("Presence pushes are ignored while signed out")
    func signedOutIgnoresPresence() async {
        let (controller, client, _) = makeController()
        let restCallsBefore = client.machineTokens.count

        controller.reconcilePresence(with: [testMachine("m1")])
        try? await Task.sleep(for: .milliseconds(400))
        #expect(client.machineTokens.count == restCallsBefore)
        #expect(controller.machines.isEmpty)
    }
}
