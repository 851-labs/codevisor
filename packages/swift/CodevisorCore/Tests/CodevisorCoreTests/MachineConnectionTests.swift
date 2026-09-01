import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// Background machine connections: every registered machine keeps its own
/// live event stream, independent of which machine is selected.
@MainActor
@Suite("MachineConnection streams")
struct MachineConnectionTests {
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
    ) throws -> (controller: MachineController, projectList: ProjectListModel) {
        let store = InMemoryStore()
        try store.saveData(
            JSONEncoder().encode(
                MachineRegistry(selectedMachineId: "local", remoteMachines: remotes)
            ),
            forKey: "machines"
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: store,
            projectList: projectList,
            clientFactory: { machine in fakes[machine.id] ?? SyncFakeServerClient(projects: [], sessions: []) }
        )
        return (controller, projectList)
    }

    private func makeSession(id: UUID, projectId: UUID, serverId: String) -> ServerSession {
        ServerSession(
            id: id.uuidString,
            projectId: projectId.uuidString,
            serverId: serverId,
            harnessId: "claude-code",
            agentSessionId: nil,
            title: "Background work",
            origin: .codevisor,
            isArchived: false,
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: "2026-06-30T00:00:02.000Z",
            usage: nil
        )
    }

    private func payload(for session: ServerSession) -> JSONValue {
        .object([
            "id": .string(session.id),
            "projectId": .string(session.projectId),
            "serverId": .string(session.serverId),
            "harnessId": .string(session.harnessId),
            "title": .string(session.title),
            "origin": .string(session.origin.rawValue),
            "isArchived": .bool(session.isArchived),
            "createdAt": .string(session.createdAt),
            "updatedAt": .string(session.updatedAt ?? session.createdAt),
        ])
    }

    @Test("Connecting a background machine pulls its full snapshot")
    func connectSnapshotsBackgroundMachine() async throws {
        let remote = makeRemote("remote-a")
        let project = Project.fromFolder(
            URL(fileURLWithPath: "/tmp/remote-work"),
            serverId: remote.id,
            origin: .codevisor
        )
        let session = makeSession(id: UUID(), projectId: project.id, serverId: remote.id)
        let fake = SyncFakeServerClient(
            projects: [serverProject(from: project)],
            sessions: [session]
        )
        let (controller, projectList) = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: fake],
            remotes: [remote]
        )

        await controller.connectMachine(remote.id)

        // The machine was never selected, yet its chats are in the shared
        // repositories — the flattened sidebar's precondition.
        #expect(
            projectList.sessions.contains {
                $0.serverId == remote.id && $0.id.uuidString == session.id
            })
        // And it landed its own terminal sync state: fleet-aggregated UIs
        // count every machine, not just the selected one.
        #expect(controller.navigationSyncStateByMachineId[remote.id] == .current)
        controller.stopEventSync()
    }

    @Test("An unreachable background machine lands a terminal stale state")
    func connectMarksUnreachableMachineStale() async throws {
        let remote = makeRemote("remote-down")
        let down = SyncFakeServerClient(projects: [], sessions: [])
        down.lock.withLock { down.downtimeRemaining = 100 }
        let (controller, _) = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: down],
            remotes: [remote]
        )

        await controller.connectMachine(remote.id)

        // Unreachable is an answer: the aggregation can count this machine
        // as failed instead of waiting on it forever.
        guard case .stale = controller.navigationSyncStateByMachineId[remote.id] else {
            Issue.record(
                "Expected .stale, got \(String(describing: controller.navigationSyncStateByMachineId[remote.id]))")
            return
        }
        controller.stopEventSync()
    }

    private func waitForSync(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for sync condition")
    }

    @Test("A background machine's live events apply while another machine is selected")
    func backgroundEventsApply() async throws {
        let remote = makeRemote("remote-a")
        let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
        let (controller, projectList) = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
            remotes: [remote]
        )
        #expect(controller.selectedMachineId == "local")

        await controller.connectMachine(remote.id)
        // The subscription attaches inside the stream task; give it a beat.
        try await waitForSync { remoteFake.eventStreamSubscriberCount == 1 }

        let session = makeSession(id: UUID(), projectId: UUID(), serverId: remote.id)
        remoteFake.emit(
            kind: "session.created",
            subjectId: session.id,
            payload: payload(for: session)
        )
        try await waitForSync {
            projectList.sessions.contains {
                $0.serverId == remote.id && $0.id.uuidString == session.id.uppercased()
            }
        }
        // The selection never moved, and the background machine's row landed
        // stamped with ITS server id.
        #expect(controller.selectedMachineId == "local")
        #expect(projectList.sessions.allSatisfy { $0.serverId == remote.id })
        controller.stopEventSync()
    }

    @Test("Switching machines leaves other machines' streams alive")
    func switchingKeepsBackgroundStreams() async throws {
        let remoteA = makeRemote("remote-a")
        let remoteB = makeRemote("remote-b")
        let fakeB = SyncFakeServerClient(projects: [], sessions: [])
        let (controller, projectList) = try makeController(
            fakes: [
                "local": SyncFakeServerClient(projects: [], sessions: []),
                remoteA.id: SyncFakeServerClient(projects: [], sessions: []),
                remoteB.id: fakeB,
            ],
            remotes: [remoteA, remoteB]
        )

        await controller.connectMachine(remoteB.id)
        try await waitForSync { fakeB.eventStreamSubscriberCount == 1 }

        // Selecting a DIFFERENT machine must not tear down B's stream.
        controller.selectMachine(remoteA.id)
        #expect(fakeB.eventStreamSubscriberCount == 1)

        let session = makeSession(id: UUID(), projectId: UUID(), serverId: remoteB.id)
        fakeB.emit(
            kind: "session.created",
            subjectId: session.id,
            payload: payload(for: session)
        )
        try await waitForSync {
            projectList.sessions.contains { $0.serverId == remoteB.id }
        }
        controller.stopEventSync()
    }

    @Test("connectMachine is idempotent while a stream is live")
    func connectIsIdempotent() async throws {
        let remote = makeRemote("remote-a")
        let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
        let (controller, _) = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
            remotes: [remote]
        )

        await controller.connectMachine(remote.id)
        await controller.connectMachine(remote.id)
        try await waitForSync { remoteFake.eventStreamSubscriberCount >= 1 }
        #expect(remoteFake.eventStreamSubscriberCount == 1)
        controller.stopEventSync()
    }

    @Test("update.changed events refresh a machine's release state live")
    func updateChangedEventApplies() async throws {
        let remote = makeRemote("remote-a")
        let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
        let (controller, _) = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
            remotes: [remote]
        )
        await controller.connectMachine(remote.id)
        try await waitForSync { remoteFake.eventStreamSubscriberCount == 1 }

        remoteFake.emit(
            kind: "update.changed",
            subjectId: "server",
            payload: .object([
                "currentVersion": .string("0.1.0"),
                "latestVersion": .string("9.9.9"),
                "updateAvailable": .bool(true),
                "channel": .string("stable"),
                "migrationState": .string("idle"),
            ])
        )
        try await waitForSync {
            controller.updateInfoByMachineId[remote.id]?.latestVersion == "9.9.9"
        }
        controller.stopEventSync()
    }

    @Test("An update tracks on its own machine, not on the selected one")
    func updatePhaseIsPerMachine() async throws {
        let remote = makeRemote("remote-a")
        let remoteFake = SyncFakeServerClient(projects: [], sessions: [])
        remoteFake.configureUpdate(current: "0.1.0", latest: "0.2.0")
        remoteFake.configureBusy(true)
        let (controller, _) = try makeController(
            fakes: ["local": SyncFakeServerClient(projects: [], sessions: []), remote.id: remoteFake],
            remotes: [remote]
        )
        #expect(controller.selectedMachineId == "local")

        await controller.updateServer(machineId: remote.id)

        // The busy refusal lands on the REMOTE machine's phase; the selected
        // machine's projection stays idle.
        if case .failed = controller.connection(for: remote.id).updatePhase {
        } else {
            Issue.record("Expected the remote machine's phase to be failed")
        }
        #expect(controller.serverUpdatePhase(for: "local") == .idle)
        controller.stopEventSync()
    }

    @Test("refreshServerUpdates probes every reachable machine")
    func fleetUpdateRefresh() async throws {
        let remoteA = makeRemote("remote-a")
        let remoteB = makeRemote("remote-b")
        let fakeA = SyncFakeServerClient(projects: [], sessions: [])
        let fakeB = SyncFakeServerClient(projects: [], sessions: [])
        fakeA.configureUpdate(current: "0.1.0", latest: "0.2.0")
        fakeB.configureUpdate(current: "0.1.0", latest: "0.3.0")
        let (controller, _) = try makeController(
            fakes: [
                "local": SyncFakeServerClient(projects: [], sessions: []),
                remoteA.id: fakeA,
                remoteB.id: fakeB,
            ],
            remotes: [remoteA, remoteB]
        )

        // Connect both so their reachability is known, then sweep.
        await controller.connectMachine(remoteA.id)
        await controller.connectMachine(remoteB.id)
        await controller.refreshServerUpdates()

        #expect(controller.updateInfoByMachineId[remoteA.id]?.latestVersion == "0.2.0")
        #expect(controller.updateInfoByMachineId[remoteB.id]?.latestVersion == "0.3.0")
        // The periodic sweep reads each server's CACHED check — forcing is
        // reserved for the user's explicit "Check Again", or every client
        // would hammer the release origin on every pass.
        #expect(fakeA.updateInfoRefreshes.last == false)
        #expect(fakeB.updateInfoRefreshes.last == false)
        controller.stopEventSync()
    }

    @Test("ensureBackgroundConnections opens a stream for every non-selected machine")
    func ensureConnectsRegisteredMachines() async throws {
        let remoteA = makeRemote("remote-a")
        let remoteB = makeRemote("remote-b")
        let fakeA = SyncFakeServerClient(projects: [], sessions: [])
        let fakeB = SyncFakeServerClient(projects: [], sessions: [])
        let (controller, _) = try makeController(
            fakes: [
                "local": SyncFakeServerClient(projects: [], sessions: []),
                remoteA.id: fakeA,
                remoteB.id: fakeB,
            ],
            remotes: [remoteA, remoteB]
        )

        controller.ensureBackgroundConnections()
        try await waitForSync {
            fakeA.eventStreamSubscriberCount == 1 && fakeB.eventStreamSubscriberCount == 1
        }
        controller.stopEventSync()
    }
}
