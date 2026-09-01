import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// The fleet-wide update fold: components across machines, per-row actions,
/// and the ordered update-all.
@MainActor
@Suite("UpdateCenter")
struct UpdateCenterTests {
    private func makeRemote(_ id: String) -> CodevisorMachine {
        CodevisorMachine(
            id: id,
            name: id,
            baseURL: URL(string: "http://\(id).test:49361")!,
            kind: "remote"
        )
    }

    private func makeController(
        fakes: [String: SyncFakeServerClient],
        remotes: [CodevisorMachine]
    ) throws -> MachineController {
        let store = InMemoryStore()
        try store.saveData(
            JSONEncoder().encode(
                MachineRegistry(selectedMachineId: "local", remoteMachines: remotes)
            ),
            forKey: "machines"
        )
        return MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            clientFactory: { machine in
                fakes[machine.id] ?? SyncFakeServerClient(projects: [], sessions: [])
            },
            updatePollInterval: .milliseconds(2),
            updatePollAttempts: 50
        )
    }

    private func makeHarness(updateAvailable: Bool) -> ServerHarness {
        ServerHarness(
            id: "claude-code",
            name: "Claude Code",
            symbolName: "sparkles",
            source: "builtin",
            launchKind: "cli",
            enabled: true,
            readiness: ServerHarnessReadiness(state: "ready", version: "1.0.0"),
            updateInfo: ServerHarnessUpdateInfo(
                installedVersion: "1.0.0",
                latestVersion: updateAvailable ? "1.2.0" : "1.0.0",
                updateAvailable: updateAvailable
            )
        )
    }

    private func makePluginUpdate() -> ServerPluginUpdateStatus {
        ServerPluginUpdateStatus(
            pluginId: "notes",
            installedVersion: "1.0.0",
            state: .available,
            checkedAt: "2026-06-30T00:00:00.000Z",
            registryVersion: "1.1.0"
        )
    }

    @Test("Components fold servers, harnesses, and plugins across machines")
    func componentsFold() async throws {
        let remote = makeRemote("remote-a")
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        fake.configureHarnesses([makeHarness(updateAvailable: true)])
        fake.configurePluginUpdates([makePluginUpdate()])
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )
        let center = UpdateCenter(
            machines: controller,
            appUpdate: AppUpdateModel(currentVersion: "1.0.0")
        )

        await controller.refreshStatus(for: remote.id)
        await center.refresh()

        let ids = center.components.map(\.id).sorted()
        #expect(
            ids == [
                "harness:remote-a:claude-code",
                "plugin:remote-a:notes",
                "server:remote-a",
            ])
        #expect(center.availableCount == 3)
        let server = center.components.first { $0.kind == .server }
        #expect(server?.machineName == "remote-a")
        #expect(server?.latestVersion == "0.2.0")
        controller.stopEventSync()
    }

    @Test("updateAll runs plugins, then harnesses, then servers, app last")
    func updateAllOrder() async throws {
        let remote = makeRemote("remote-a")
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        fake.configureHarnesses([makeHarness(updateAvailable: true)])
        fake.configurePluginUpdates([makePluginUpdate()])
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )
        let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
        appUpdate.checkHandler = { _ in }
        var appInstalledAfterOperations: Int?
        appUpdate.installHandler = { _ in
            appInstalledAfterOperations = fake.operationLog.count
        }
        appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
        let center = UpdateCenter(machines: controller, appUpdate: appUpdate)

        await controller.refreshStatus(for: remote.id)
        await center.refresh()
        #expect(center.availableCount == 4)

        await center.updateAll()

        // Restart-free components first, then the remote server, then the
        // app — whose install restarts this client.
        #expect(
            fake.operationLog == [
                "plugin.prepare:notes",
                "plugin.apply:notes",
                "harness.update:claude-code",
                "server.apply",
            ])
        #expect(appInstalledAfterOperations == 4)
        controller.stopEventSync()
    }

    @Test("updateAll clears its session when no app restart is pending")
    func sessionClearsWithoutAppRestart() async throws {
        let remote = makeRemote("remote-a")
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureHarnesses([makeHarness(updateAvailable: true)])
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )
        let store = InMemoryStore()
        let center = UpdateCenter(
            machines: controller,
            appUpdate: AppUpdateModel(currentVersion: "1.0.0"),
            store: store
        )
        await controller.refreshStatus(for: remote.id)
        await center.refresh()

        await center.updateAll()

        #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
        controller.stopEventSync()
    }

    @Test("App updates dismiss the update sheet before invoking Sparkle")
    func appUpdateDismissesSheet() async throws {
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: [])],
            remotes: []
        )
        let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
        appUpdate.checkHandler = { _ in }
        let center = UpdateCenter(machines: controller, appUpdate: appUpdate)
        var sheetWasPresentedWhenInstallStarted: Bool?
        appUpdate.installHandler = { _ in
            sheetWasPresentedWhenInstallStarted = center.isPresented
        }
        appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
        center.isPresented = true

        let component = try #require(center.components.first { $0.kind == .app })
        await center.update(component)

        #expect(!center.isPresented)
        #expect(sheetWasPresentedWhenInstallStarted == false)
        controller.stopEventSync()
    }

    @Test("An app update leaves the session for the relaunched client")
    func appUpdateLeavesSessionForRelaunch() async throws {
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: [])],
            remotes: []
        )
        let store = InMemoryStore()
        let appUpdate = AppUpdateModel(currentVersion: "1.0.0")
        appUpdate.checkHandler = { _ in }
        appUpdate.installHandler = { _ in }
        appUpdate.reportAvailable(version: "2.0.0", releasePageURL: nil)
        let center = UpdateCenter(machines: controller, appUpdate: appUpdate, store: store)

        await center.updateAll()
        // Sparkle is about to restart this client: the marker survives.
        #expect(store.loadData(forKey: "updateCenter.pendingSession") != nil)

        // The relaunched app consumes it: surface reopens, session clears.
        let relaunched = UpdateCenter(
            machines: controller,
            appUpdate: AppUpdateModel(currentVersion: "2.0.0"),
            store: store
        )
        await relaunched.resumePendingSessionIfNeeded()
        #expect(relaunched.isPresented)
        #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
        controller.stopEventSync()
    }

    @Test("A crashed run's session resumes what is still pending")
    func resumesPendingSession() async throws {
        let remote = makeRemote("remote-a")
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureHarnesses([makeHarness(updateAvailable: true)])
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )
        let store = InMemoryStore()
        try store.saveData(
            JSONEncoder().encode(["harness:remote-a:claude-code"]),
            forKey: "updateCenter.pendingSession"
        )
        let center = UpdateCenter(
            machines: controller,
            appUpdate: AppUpdateModel(currentVersion: "1.0.0"),
            store: store
        )
        await controller.refreshStatus(for: remote.id)

        await center.resumePendingSessionIfNeeded()

        #expect(center.isPresented)
        #expect(fake.operationLog.contains("harness.update:claude-code"))
        #expect(store.loadData(forKey: "updateCenter.pendingSession") == nil)
        controller.stopEventSync()
    }

    @Test("Harness lifecycle changes re-read that machine's inventory")
    func lifecycleRefetch() async throws {
        let remote = makeRemote("remote-a")
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        fake.configureHarnesses([makeHarness(updateAvailable: true)])
        let controller = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )
        let center = UpdateCenter(
            machines: controller,
            appUpdate: AppUpdateModel(currentVersion: "1.0.0")
        )
        await controller.refreshStatus(for: remote.id)
        await center.refresh()
        #expect(center.availableCount == 1)

        // The machine finished its update: the next lifecycle event makes
        // the row disappear without a full sweep.
        fake.configureHarnesses([makeHarness(updateAvailable: false)])
        center.noteHarnessLifecycleChanged(onServer: remote.id)
        for _ in 0..<200 {
            if center.availableCount == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(center.availableCount == 0)
        controller.stopEventSync()
    }
}
