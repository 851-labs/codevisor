import CodevisorClient
import CodevisorProtocol
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("CloudAccountController registration ordering")
struct CloudAccountControllerRegistrationOrderingTests {
    @Test("A new local identity resolves before the refreshed roster is published")
    func newLocalIdentityPrecedesRoster() async throws {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!
            )
        )
        controller.localServerClient = FakeLocalServerClient()
        var events: [String] = []
        controller.onLocalMachineRegistrationResolved = {
            events.append("identity:\($0)")
        }
        controller.onMachinesRefreshed = { events.append("roster") }
        try store.saveToken("dev-token")

        await controller.bootstrap()

        #expect(events == ["identity:local-device-1", "roster"])
        #expect(client.machineTokens.count == 2)
    }

    @Test("An existing local identity resolves before the roster is published")
    func existingLocalIdentityPrecedesRoster() async throws {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        client.machinesResult = .success([testMachine("external-device")])
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!
            )
        )
        controller.localServerClient = FakeLocalServerClient(
            registration: ServerCloudRegistration(
                connected: true,
                deviceId: "external-device",
                state: "connected",
                managedBy: "external"
            )
        )
        var events: [String] = []
        controller.onLocalMachineRegistrationResolved = {
            events.append("identity:\($0)")
        }
        controller.onMachinesRefreshed = { events.append("roster") }
        try store.saveToken("dev-token")

        await controller.bootstrap()

        #expect(events == ["identity:external-device", "roster"])
        #expect(client.machineTokens.count == 1)
    }
}
