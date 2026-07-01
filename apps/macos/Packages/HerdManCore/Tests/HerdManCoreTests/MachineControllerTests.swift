import Foundation
import Testing
@testable import HerdManCore

@MainActor
@Suite("MachineController")
struct MachineControllerTests {
    @Test("Registry starts with local machine selected")
    func localDefault() {
        let (controller, workspaceList, _) = makeController()

        #expect(controller.machines == [.local])
        #expect(controller.selectedMachine == .local)
        #expect(workspaceList.selectedServerId == "local")
    }

    @Test("Remote host input normalizes to an HTTP server URL")
    func normalizedRemoteURL() throws {
        #expect(try MachineController.normalizedRemoteURL(from: "mac-mini.tailnet.ts.net").absoluteString == "http://mac-mini.tailnet.ts.net:49361")
        #expect(try MachineController.normalizedRemoteURL(from: "https://10.0.0.5:9999/path?x=1").absoluteString == "https://10.0.0.5:9999")
        #expect(throws: MachineControllerError.invalidHost(" ")) {
            _ = try MachineController.normalizedRemoteURL(from: " ")
        }
    }

    @Test("Adding and selecting remotes persists the registry")
    func addSelectAndPersistRemote() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)
        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")

        #expect(remote.id == "remote-mac-mini-tailnet-ts-net-49361")
        #expect(remote.name == "mac-mini.tailnet.ts.net")
        #expect(first.controller.selectedMachine == remote)
        #expect(first.workspaceList.selectedServerId == remote.id)

        first.controller.selectMachine("local")
        #expect(first.workspaceList.selectedServerId == "local")

        let second = makeController(store: store)
        #expect(second.controller.machines.contains(remote))
        #expect(second.controller.selectedMachine == .local)
        #expect(second.workspaceList.selectedServerId == "local")

        let duplicate = try second.controller.addRemote(host: "http://mac-mini.tailnet.ts.net:49361")
        #expect(duplicate == remote)
        #expect(second.controller.machines.filter { $0 == remote }.count == 1)
    }

    @Test("Removing the selected remote falls back to local")
    func removeSelectedRemote() throws {
        let (controller, workspaceList, _) = makeController()
        let remote = try controller.addRemote(host: "10.0.0.5")

        try controller.removeMachine(remote.id)

        #expect(controller.selectedMachine == .local)
        #expect(controller.machines == [.local])
        #expect(workspaceList.selectedServerId == "local")
        #expect(throws: MachineControllerError.cannotRemoveLocal) {
            try controller.removeMachine("local")
        }
    }

    private func makeController(store: InMemoryStore = InMemoryStore()) -> (
        controller: MachineController,
        workspaceList: WorkspaceListModel,
        store: InMemoryStore
    ) {
        let workspaceList = WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(store: store, workspaceList: workspaceList)
        return (controller, workspaceList, store)
    }
}
