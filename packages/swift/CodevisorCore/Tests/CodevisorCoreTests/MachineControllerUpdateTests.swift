import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

/// Server self-update flows: check/apply round trips, restart confirmation,
/// and failure surfacing. Split from MachineControllerTests.swift to keep
/// that suite within size limits.
@MainActor
@Suite("MachineController server updates")
struct MachineControllerUpdateTests {
    @Test("Client-triggered server update waits for the restart and reconnects")
    func remoteServerUpdate() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )

        await controller.refreshStatus(for: "local")
        #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == true)
        #expect(controller.serverUpdateInfo(for: "local")?.latestVersion == "0.2.0")

        await controller.updateServer(machineId: "local")

        #expect(fake.appliedUpdates == 1)
        #expect(controller.serverUpdatePhase(for: "local") == .idle)
        // After the restart the banner state clears and the status shows the
        // new version.
        #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
        #expect(controller.statusByMachineId["local"]?.label.contains("0.2.0") == true)
        controller.stopEventSync()

        // Triggering again is a no-op that just refreshes state.
        await controller.updateServer(machineId: "local")
        #expect(controller.serverUpdatePhase(for: "local") == .idle)
        #expect(fake.appliedUpdates == 2)
    }

    @Test("Update checks and installs follow the app's release channel")
    func remoteServerUpdateChannel() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )

        // Stable by default.
        await controller.refreshStatus(for: "local")
        #expect(fake.updateInfoChannels == [.stable])

        // Alpha once the app opts in — checks and installs alike.
        controller.serverUpdateChannel = .alpha
        await controller.refreshStatus(for: "local")
        #expect(fake.updateInfoChannels.last == .alpha)
        await controller.updateServer(machineId: "local")
        #expect(fake.appliedChannels == [.alpha])
        controller.stopEventSync()
    }

    @Test("Periodic selected-server refresh force-checks a remote machine")
    func periodicRemoteServerUpdateRefresh() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        let remote = CodevisorMachine(
            id: "remote-test",
            name: "Remote",
            baseURL: URL(string: "http://remote.test:49361")!,
            kind: "remote"
        )
        let store = InMemoryStore()
        try store.saveData(
            JSONEncoder().encode(
                MachineRegistry(selectedMachineId: remote.id, remoteMachines: [remote])
            ),
            forKey: "machines"
        )
        let controller = MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            clientFactory: { _ in fake }
        )

        await controller.refreshServerUpdate(for: remote.id)

        #expect(fake.updateInfoRefreshes == [true])
        #expect(controller.serverUpdateInfo(for: remote.id)?.updateAvailable == true)
    }

    @Test("Remote update accepts a channel-current runtime whose version string differs")
    func remoteServerUpdateVersionMismatch() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(
            current: "0.1.97",
            latest: "0.1.97-alpha.55",
            installedVersion: "0.1.97"
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )
        controller.serverUpdateChannel = .alpha

        await controller.refreshStatus(for: "local")
        await controller.updateServer(machineId: "local")

        #expect(controller.serverUpdatePhase(for: "local") == .idle)
        #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
        #expect(controller.statusByMachineId["local"]?.label.contains("0.1.97") == true)
        controller.stopEventSync()
    }

    @Test("Build numbers confirm convergence when version strings differ")
    func remoteServerUpdateBuildNumberConvergence() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(
            current: "0.1.97",
            latest: "0.1.97-alpha.55",
            installedVersion: "0.1.97",
            currentBuildNumber: 100,
            targetBuildNumber: 200
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )
        controller.serverUpdateChannel = .alpha

        await controller.refreshStatus(for: "local")
        #expect(controller.serverUpdateInfo(for: "local")?.latestBuildNumber == 200)
        await controller.updateServer(machineId: "local")

        #expect(fake.appliedUpdates == 1)
        #expect(controller.serverUpdatePhase(for: "local") == .idle)
        #expect(controller.serverUpdateInfo(for: "local")?.updateAvailable == false)
        controller.stopEventSync()
    }

    @Test("A failed unattended install surfaces the machine's reason")
    func remoteServerUpdateHandoffFailure() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        fake.configureApplyFailure(message: "Sparkle could not verify the update signature.")
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )

        await controller.refreshStatus(for: "local")
        await controller.updateServer(machineId: "local")

        #expect(fake.appliedUpdates == 1)
        if case let .failed(message) = controller.serverUpdatePhase(for: "local") {
            #expect(message.contains("signature"))
        } else {
            Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase(for: "local"))")
        }
        controller.stopEventSync()
    }

    @Test("A busy server declines the update with a clear message")
    func remoteServerUpdateRefusedWhileBusy() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        fake.configureBusy(true)
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )

        await controller.updateServer(machineId: "local")

        // The server declined (chats running), so the phase reports a failure
        // and the update was not applied/restarted.
        if case let .failed(message) = controller.serverUpdatePhase(for: "local") {
            #expect(message.contains("chats running"))
        } else {
            Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase(for: "local"))")
        }
        controller.stopEventSync()
    }
}
