import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("MachineController")
struct MachineControllerTests {
    @Test("Registry starts with local machine selected")
    func localDefault() {
        let (controller, projectList, _) = makeController()

        #expect(controller.machines == [.local])
        #expect(controller.selectedMachine == .local)
        #expect(projectList.selectedServerId == "local")
    }

    @Test("Remote host input normalizes to an HTTP server URL")
    func normalizedRemoteURL() throws {
        #expect(
            try MachineController.normalizedRemoteURL(from: "mac-mini.tailnet.ts.net").absoluteString
                == "http://mac-mini.tailnet.ts.net:49361")
        #expect(
            try MachineController.normalizedRemoteURL(from: "https://10.0.0.5:9999/path?x=1").absoluteString
                == "https://10.0.0.5:9999")
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
        #expect(first.projectList.selectedServerId == remote.id)

        first.controller.selectMachine("local")
        #expect(first.projectList.selectedServerId == "local")

        let second = makeController(store: store)
        #expect(second.controller.machines.contains(remote))
        #expect(second.controller.selectedMachine == .local)
        #expect(second.projectList.selectedServerId == "local")

        let duplicate = try second.controller.addRemote(host: "http://mac-mini.tailnet.ts.net:49361")
        #expect(duplicate == remote)
        #expect(second.controller.machines.filter { $0 == remote }.count == 1)
    }

    @Test("Remote tokens persist and flow into the server config")
    func remoteTokens() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)

        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", token: " hm_secret ")
        #expect(remote.token == "hm_secret")
        #expect(remote.serverConfig.bearerToken == "hm_secret")

        // Re-adding with a new token rotates it; without one keeps it.
        _ = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", token: "hm_rotated")
        #expect(first.controller.machine(for: remote.id)?.token == "hm_rotated")
        _ = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")
        #expect(first.controller.machine(for: remote.id)?.token == "hm_rotated")

        // The token survives a reload from the persisted registry.
        let second = makeController(store: store)
        #expect(second.controller.machine(for: remote.id)?.token == "hm_rotated")

        // The local machine never carries a token.
        #expect(CodevisorMachine.local.token == nil)
        #expect(CodevisorMachine.local.serverConfig.bearerToken == nil)
    }

    @Test("Live credential storage keeps tokens out of the machine registry")
    func remoteTokensUseCredentialStore() throws {
        let store = InMemoryStore()
        let credentials = InMemoryMachineCredentialStore()
        let first = MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            credentialStore: credentials
        )

        let remote = try first.addRemote(
            host: "mac-mini.tailnet.ts.net",
            token: "device-secret"
        )
        #expect(try credentials.token(forMachineID: remote.id) == "device-secret")

        let persisted = try JSONDecoder().decode(
            MachineRegistry.self,
            from: #require(store.loadData(forKey: "machines"))
        )
        #expect(persisted.remoteMachines.first?.token == nil)

        let second = MachineController(
            store: store,
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            credentialStore: credentials
        )
        #expect(second.machine(for: remote.id)?.token == "device-secret")

        try second.removeMachine(remote.id)
        #expect(try credentials.token(forMachineID: remote.id) == nil)
    }

    @Test("Remotes can be named on add and renamed later, persisted")
    func namedAndRenamedRemote() throws {
        let store = InMemoryStore()
        let first = makeController(store: store)

        let remote = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", name: "  Mac mini  ")
        #expect(remote.name == "Mac mini")

        // Re-adding the same host with a name updates it; without one keeps it.
        let renamedViaAdd = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net", name: "Studio")
        #expect(renamedViaAdd.id == remote.id)
        #expect(first.controller.machine(for: remote.id)?.name == "Studio")
        _ = try first.controller.addRemote(host: "mac-mini.tailnet.ts.net")
        #expect(first.controller.machine(for: remote.id)?.name == "Studio")

        try first.controller.renameMachine(remote.id, to: "Build box")
        #expect(first.controller.machine(for: remote.id)?.name == "Build box")
        // Blank names are ignored.
        try first.controller.renameMachine(remote.id, to: "   ")
        #expect(first.controller.machine(for: remote.id)?.name == "Build box")

        #expect(throws: MachineControllerError.cannotRenameLocal) {
            try first.controller.renameMachine("local", to: "My Mac")
        }

        let second = makeController(store: store)
        #expect(second.controller.machine(for: remote.id)?.name == "Build box")
    }

    @Test("Legacy machine icon metadata is ignored and stripped on the next save")
    func legacyAppearanceMetadataIsRemoved() throws {
        let legacyRegistry = """
            {
              "selectedMachineId": "remote-studio-49361",
              "localAppearance": {"symbolName": "laptopcomputer"},
              "cloudAppearances": {"cloud:dev-1": {"symbolName": "server.rack"}},
              "remoteMachines": [{
                "id": "remote-studio-49361",
                "name": "Studio",
                "baseURL": "http://studio:49361",
                "kind": "remote",
                "appearance": {"symbolName": "externaldrive"}
              }]
            }
            """
        let store = InMemoryStore()
        try store.saveData(Data(legacyRegistry.utf8), forKey: "machines")

        let controller = makeController(store: store).controller
        try controller.renameMachine("remote-studio-49361", to: "Build box")

        let persistedData = try #require(store.loadData(forKey: "machines"))
        let persisted = try #require(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        #expect(persisted["localAppearance"] == nil)
        #expect(persisted["cloudAppearances"] == nil)
        let remotes = try #require(persisted["remoteMachines"] as? [[String: Any]])
        #expect(remotes.first?["appearance"] == nil)
    }

    @Test("Removing the selected remote falls back to local")
    func removeSelectedRemote() throws {
        let (controller, projectList, _) = makeController()
        let remote = try controller.addRemote(host: "10.0.0.5")

        try controller.removeMachine(remote.id)

        #expect(controller.selectedMachine == .local)
        #expect(controller.machines == [.local])
        #expect(projectList.selectedServerId == "local")
        #expect(throws: MachineControllerError.cannotRemoveLocal) {
            try controller.removeMachine("local")
        }
    }

    @Test("Validated add rejects a bad token and adds a reachable machine")
    func validatedAdd() async throws {
        let store = InMemoryStore()
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        // A client whose probe rejects the token: the machine must not be added.
        let rejecting = MachineController(
            store: store,
            projectList: projectList,
            clientFactory: { _ in
                RescanCountingClient(infoError: CodevisorServerClientError.httpStatus(401, "{}"))
            }
        )
        await #expect(throws: (any Error).self) {
            try await rejecting.addRemoteValidating(host: "10.0.0.5", token: "hm_wrong")
        }
        #expect(rejecting.machines == [.local])

        // A client that answers: the machine is added and selected.
        let accepting = MachineController(
            store: InMemoryStore(),
            projectList: ProjectListModel(
                projectRepository: DefaultProjectRepository(store: InMemoryStore()),
                sessionRepository: DefaultSessionRepository(store: InMemoryStore())
            ),
            clientFactory: { _ in RescanCountingClient() }
        )
        let added = try await accepting.addRemoteValidating(host: "10.0.0.5", token: "hm_ok")
        #expect(accepting.machines.contains(added))
        #expect(accepting.selectedMachine == added)
    }

    @Test("Server events keep projects and sessions in sync across clients")
    func eventSyncRefreshesAndRemoves() async throws {
        let projectId = UUID()
        let sessionId = UUID()
        let fake = SyncFakeServerClient(
            projects: [
                ServerProject(
                    id: projectId.uuidString,
                    name: "Shared",
                    isArchived: false,
                    origin: .codevisor,
                    createdAt: "2026-06-30T00:00:00.000Z",
                    locations: [
                        ServerProjectLocation(
                            id: UUID().uuidString,
                            projectId: projectId.uuidString,
                            serverId: "local",
                            folderPath: "/tmp/shared",
                            createdAt: "2026-06-30T00:00:00.000Z",
                            isGitRepository: nil
                        )
                    ]
                )
            ],
            sessions: []
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake }
        )

        // Another client creates a session on the same server.
        controller.startEventSync()
        fake.setSessions([
            ServerSession(
                id: sessionId.uuidString,
                projectId: projectId.uuidString,
                serverId: "local",
                harnessId: "claude-code",
                agentSessionId: nil,
                title: "From another client",
                origin: .codevisor,
                isArchived: false,
                createdAt: "2026-06-30T00:00:01.000Z",
                updatedAt: nil,
                usage: nil
            )
        ])
        fake.emit(kind: "session.created", subjectId: sessionId.uuidString)
        try await waitForSync { projectList.sessions.contains { $0.id == sessionId } }
        #expect(projectList.projects.contains { $0.id == projectId })

        // Ordinary session events carry their authoritative summary. Applying
        // one must update only that cached row instead of listing and mapping
        // every session again.
        let fullRefreshCount = fake.listSessionCallCount
        let updated = ServerSession(
            id: sessionId.uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            harnessId: "claude-code",
            agentSessionId: nil,
            title: "Updated incrementally",
            origin: .codevisor,
            isArchived: false,
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: "2026-06-30T00:00:02.000Z",
            usage: nil
        )
        fake.emit(
            kind: "session.updated",
            subjectId: sessionId.uuidString,
            payload: sessionPayload(updated)
        )
        try await waitForSync {
            projectList.sessions.first(where: { $0.id == sessionId })?.title
                == "Updated incrementally"
        }
        #expect(fake.listSessionCallCount == fullRefreshCount)

        // Another client deletes the session, then the project.
        fake.setSessions([])
        fake.emit(kind: "session.deleted", subjectId: sessionId.uuidString)
        try await waitForSync { !projectList.sessions.contains { $0.id == sessionId } }

        fake.setProjects([])
        fake.emit(kind: "project.deleted", subjectId: projectId.uuidString)
        try await waitForSync { !projectList.projects.contains { $0.id == projectId } }

        controller.stopEventSync()
    }

    @Test("Plugin events bridge list invalidation and per-plugin reloads")
    func pluginEventBridging() async throws {
        let fake = SyncFakeServerClient(projects: [], sessions: [])
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            clientFactory: { _ in fake }
        )
        var stateChanges: [String] = []
        var updates: [[String]] = []
        controller.onPluginStateChanged = { stateChanges.append($0) }
        controller.onPluginUpdated = { updates.append([$0, $1]) }

        controller.startEventSync()
        // Runtime transitions invalidate the machine's plugin list…
        fake.emit(kind: "plugin.state.updated", subjectId: "owner.example")
        // …while only plugin.updated (code/install changed) triggers pane
        // reloads, carrying the plugin id so unrelated panes stay put.
        fake.emit(kind: "plugin.updated", subjectId: "owner.example")
        try await waitForSync { updates == [["local", "owner.example"]] }
        #expect(stateChanges == ["local"])

        controller.stopEventSync()
    }

    @Test("Workspace and unarchive events drive shared navigation state")
    func workspaceEventSync() async throws {
        let projectId = UUID()
        let sessionId = UUID()
        let siblingSessionId = UUID()
        let workspaceId = UUID()
        let project = ServerProject(
            id: projectId.uuidString,
            name: "Shared",
            isArchived: false,
            origin: .codevisor,
            createdAt: "2026-06-30T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: UUID().uuidString,
                    projectId: projectId.uuidString,
                    serverId: "local",
                    folderPath: "/tmp/shared",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    isGitRepository: nil
                )
            ]
        )
        func serverSession(id: UUID, isArchived: Bool, workspaceId: UUID?) -> ServerSession {
            ServerSession(
                id: id.uuidString,
                projectId: projectId.uuidString,
                serverId: "local",
                harnessId: "codex",
                agentSessionId: nil,
                title: "Shared chat",
                origin: .codevisor,
                isArchived: isArchived,
                worktreeName: nil,
                workspaceId: workspaceId?.uuidString,
                cwd: "/tmp/shared",
                createdAt: "2026-06-30T00:00:01.000Z",
                updatedAt: nil,
                usage: nil
            )
        }
        func serverWorkspace(isArchived: Bool) -> ServerWorkspace {
            ServerWorkspace(
                id: workspaceId.uuidString,
                serverId: "local",
                projectId: projectId.uuidString,
                name: "Shared workspace",
                hasCustomName: true,
                rootDirectory: "/tmp/shared",
                isArchived: isArchived,
                archivedAt: isArchived ? "2026-06-30T00:00:02.000Z" : nil,
                createdAt: "2026-06-30T00:00:00.000Z",
                updatedAt: nil
            )
        }

        let fake = SyncFakeServerClient(
            projects: [project],
            sessions: [
                serverSession(id: sessionId, isArchived: false, workspaceId: workspaceId),
                serverSession(id: siblingSessionId, isArchived: false, workspaceId: workspaceId),
            ],
            workspaces: [serverWorkspace(isArchived: false)]
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let workspaceRepository = DefaultWorkspaceRepository(store: InMemoryStore())
        let workspaceSync = WorkspaceSyncModel(
            repository: workspaceRepository,
            projectList: projectList
        )
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            workspaceSync: workspaceSync,
            clientFactory: { _ in fake }
        )

        // Production establishes one authoritative snapshot before opening
        // the live-only event stream.
        await controller.refreshSelectedNavigationState()
        controller.startEventSync()
        fake.emit(kind: "workspace.updated", subjectId: workspaceId.uuidString)
        try await waitForSync {
            workspaceRepository.workspace(id: workspaceId)?.isServerSynced == true
        }
        #expect(workspaceRepository.workspace(id: workspaceId)?.name == "Shared workspace")
        #expect(
            workspaceSync.routeDisposition(
                workspaceId: workspaceId,
                anchorSessionId: sessionId,
                serverId: "local"
            ) == .keep
        )

        // Archiving one chat selects a surviving sibling on both platforms.
        let archivedSession = serverSession(
            id: sessionId,
            isArchived: true,
            workspaceId: workspaceId
        )
        let activeSibling = serverSession(
            id: siblingSessionId,
            isArchived: false,
            workspaceId: workspaceId
        )
        fake.setSessions([archivedSession, activeSibling])
        fake.emit(
            kind: "session.archived",
            subjectId: sessionId.uuidString,
            payload: sessionPayload(archivedSession)
        )
        try await waitForSync {
            projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == true
        }
        #expect(
            workspaceSync.routeDisposition(
                workspaceId: workspaceId,
                anchorSessionId: sessionId,
                serverId: "local"
            ) == .selectSession(siblingSessionId)
        )
        #expect(
            workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local")
                == .selectSession(siblingSessionId)
        )

        // The previously missing unarchive event restores the original route.
        let unarchivedSession = serverSession(
            id: sessionId,
            isArchived: false,
            workspaceId: workspaceId
        )
        fake.setSessions([unarchivedSession, activeSibling])
        fake.emit(
            kind: "session.unarchived",
            subjectId: sessionId.uuidString,
            payload: sessionPayload(unarchivedSession)
        )
        try await waitForSync {
            projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == false
        }
        #expect(workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local") == .keep)

        let archivedSibling = serverSession(
            id: siblingSessionId,
            isArchived: true,
            workspaceId: workspaceId
        )
        fake.setSessions([archivedSession, archivedSibling])
        fake.setWorkspaces([serverWorkspace(isArchived: true)])
        fake.emit(kind: "workspace.updated", subjectId: workspaceId.uuidString)
        fake.emit(
            kind: "session.archived",
            subjectId: sessionId.uuidString,
            payload: sessionPayload(archivedSession)
        )
        fake.emit(
            kind: "session.archived",
            subjectId: siblingSessionId.uuidString,
            payload: sessionPayload(archivedSibling)
        )
        try await waitForSync {
            workspaceRepository.workspace(id: workspaceId)?.isArchived == true
                && projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == true
        }
        #expect(
            workspaceSync.routeDisposition(
                workspaceId: workspaceId,
                anchorSessionId: sessionId,
                serverId: "local"
            ) == .dismiss
        )

        let unarchivedSibling = serverSession(
            id: siblingSessionId,
            isArchived: false,
            workspaceId: workspaceId
        )
        fake.setSessions([unarchivedSession, unarchivedSibling])
        fake.setWorkspaces([serverWorkspace(isArchived: false)])
        fake.emit(kind: "workspace.updated", subjectId: workspaceId.uuidString)
        fake.emit(
            kind: "session.unarchived",
            subjectId: sessionId.uuidString,
            payload: sessionPayload(unarchivedSession)
        )
        fake.emit(
            kind: "session.unarchived",
            subjectId: siblingSessionId.uuidString,
            payload: sessionPayload(unarchivedSibling)
        )
        try await waitForSync {
            workspaceRepository.workspace(id: workspaceId)?.isArchived == false
                && projectList.sessions.first(where: { $0.id == sessionId })?.isArchived == false
        }
        #expect(workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local") == .keep)

        fake.setSessions([
            serverSession(id: sessionId, isArchived: false, workspaceId: nil),
            serverSession(id: siblingSessionId, isArchived: false, workspaceId: nil),
        ])
        fake.setWorkspaces([])
        fake.emit(kind: "workspace.deleted", subjectId: workspaceId.uuidString)
        try await waitForSync { workspaceRepository.workspace(id: workspaceId) == nil }
        #expect(workspaceSync.routeDisposition(sessionId: sessionId, serverId: "local") == .dismiss)

        controller.stopEventSync()
    }

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
        #expect(controller.selectedServerUpdate?.updateAvailable == true)
        #expect(controller.selectedServerUpdate?.latestVersion == "0.2.0")

        await controller.updateSelectedServer()

        #expect(fake.appliedUpdates == 1)
        #expect(controller.serverUpdatePhase == .idle)
        // After the restart the banner state clears and the status shows the
        // new version.
        #expect(controller.selectedServerUpdate?.updateAvailable == false)
        #expect(controller.statusByMachineId["local"]?.label.contains("0.2.0") == true)
        controller.stopEventSync()

        // Triggering again is a no-op that just refreshes state.
        await controller.updateSelectedServer()
        #expect(controller.serverUpdatePhase == .idle)
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
        await controller.updateSelectedServer()
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

        await controller.refreshSelectedServerUpdate()

        #expect(fake.updateInfoRefreshes == [true])
        #expect(controller.selectedServerUpdate?.updateAvailable == true)
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
        await controller.updateSelectedServer()

        #expect(controller.serverUpdatePhase == .idle)
        #expect(controller.selectedServerUpdate?.updateAvailable == false)
        #expect(controller.statusByMachineId["local"]?.label.contains("0.1.97") == true)
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

        await controller.updateSelectedServer()

        // The server declined (chats running), so the phase reports a failure
        // and the update was not applied/restarted.
        if case let .failed(message) = controller.serverUpdatePhase {
            #expect(message.contains("chats running"))
        } else {
            Issue.record("Expected a failed phase, got \(controller.serverUpdatePhase)")
        }
        controller.stopEventSync()
    }

    @Test("Server pane snapshots materialize remote tabs and apply live deletion")
    func workspacePaneSync() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let sessionId = UUID()
        let chatPaneId = UUID()
        let remoteTabId = UUID()
        let project = ServerProject(
            id: projectId.uuidString,
            name: "Shared",
            isArchived: false,
            origin: .codevisor,
            createdAt: "2026-06-30T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: UUID().uuidString,
                    projectId: projectId.uuidString,
                    serverId: "local",
                    folderPath: "/tmp/shared-panes",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    isGitRepository: nil
                )
            ]
        )
        let session = ServerSession(
            id: sessionId.uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            harnessId: "codex",
            agentSessionId: nil,
            title: "Chat",
            origin: .codevisor,
            isArchived: false,
            worktreeName: nil,
            workspaceId: workspaceId.uuidString,
            cwd: "/tmp/shared-panes",
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: nil,
            usage: nil
        )
        let workspace = ServerWorkspace(
            id: workspaceId.uuidString,
            serverId: "local",
            projectId: projectId.uuidString,
            name: "Shared",
            hasCustomName: false,
            rootDirectory: "/tmp/shared-panes",
            isArchived: false,
            createdAt: "2026-06-30T00:00:00.000Z"
        )
        let chatPane = ServerWorkspacePane(
            id: chatPaneId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "chat",
            title: "Chat",
            resourceKind: "session",
            resourceId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:01.000Z"
        )
        let remoteTab = ServerWorkspacePane(
            id: remoteTabId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "new-tab",
            title: "New tab",
            createdAt: "2026-06-30T00:00:02.000Z"
        )
        let fake = SyncFakeServerClient(
            projects: [project], sessions: [session], workspaces: [workspace],
            panes: [chatPane, remoteTab]
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        var legacyState = PaneGroupState.centerInitial(sessionId: sessionId)
        _ = legacyState.addChatPane(sessionId: sessionId)
        let legacyPane = legacyState.addNewTabPane()
        repository.save(
            Workspace(
                id: workspaceId,
                name: "Shared",
                rootDirectory: "/tmp/shared-panes",
                serverId: "local",
                projectId: projectId,
                centerTree: .leaf(legacyState),
                bottomGroup: PaneGroupState(),
                isServerSynced: false
            )
        )
        let workspaceSync = WorkspaceSyncModel(repository: repository, projectList: projectList)
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            workspaceSync: workspaceSync,
            clientFactory: { _ in fake }
        )

        await controller.refreshSelectedNavigationState()
        let materialized = try #require(repository.workspace(id: workspaceId))
        #expect(materialized.tabId(containingPane: remoteTabId) != nil)
        #expect(materialized.pane(containingChat: sessionId)?.id == chatPaneId)
        #expect(
            materialized.centerTabs.flatMap { $0.root.allGroups }.flatMap(\.state.panes)
                .filter { $0.chatSessionId == sessionId }.count == 1
        )
        // A coherent current-server snapshot is authoritative: hydration does
        // not upload a local-only fallback pane.
        #expect(fake.workspacePanes?.contains(where: { $0.id == legacyPane.id.uuidString }) == false)

        controller.startEventSync()
        fake.setPanes([chatPane])
        fake.emit(kind: "workspace.pane.deleted", subjectId: remoteTabId.uuidString)
        try await waitForSync {
            repository.workspace(id: workspaceId)?.tabId(containingPane: remoteTabId) == nil
        }
    }

    @Test("New workspace adoption preserves pane identity across a coherent refresh")
    func legacyWorkspacePaneAdoption() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let sessionId = UUID()
        let project = ServerProject(
            id: projectId.uuidString,
            name: "Legacy",
            isArchived: false,
            origin: .codevisor,
            createdAt: "2026-06-30T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: UUID().uuidString,
                    projectId: projectId.uuidString,
                    serverId: "local",
                    folderPath: "/tmp/legacy-workspace",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    isGitRepository: nil
                )
            ]
        )
        let session = ServerSession(
            id: sessionId.uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            harnessId: "codex",
            agentSessionId: nil,
            title: "Legacy chat",
            origin: .codevisor,
            isArchived: false,
            worktreeName: nil,
            workspaceId: nil,
            cwd: "/tmp/legacy-workspace",
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: nil,
            usage: nil
        )
        let fake = SyncFakeServerClient(
            projects: [project], sessions: [session], workspaces: [], panes: []
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        var chatState = PaneGroupState.centerInitial(sessionId: sessionId)
        let chatPaneId = try #require(
            chatState.panes.first(where: { $0.chatSessionId == sessionId })?.id
        )
        let placeholder = chatState.addNewTabPane()
        repository.save(
            Workspace(
                id: workspaceId,
                name: "Legacy",
                rootDirectory: "/tmp/legacy-workspace",
                serverId: "local",
                projectId: projectId,
                centerTree: .leaf(chatState),
                bottomGroup: PaneGroupState(),
                isServerSynced: false
            )
        )
        let workspaceSync = WorkspaceSyncModel(repository: repository, projectList: projectList)
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            workspaceSync: workspaceSync,
            clientFactory: { _ in fake }
        )

        await controller.refreshSelectedNavigationState()

        #expect(fake.workspaces.contains { UUID(uuidString: $0.id) == workspaceId })
        #expect(
            fake.sessions.first { UUID(uuidString: $0.id) == sessionId }?.workspaceId
                .flatMap(UUID.init(uuidString:)) == workspaceId
        )
        #expect(fake.workspacePanes?.contains { UUID(uuidString: $0.id) == chatPaneId } == true)
        #expect(fake.workspacePanes?.contains { UUID(uuidString: $0.id) == placeholder.id } == true)
        #expect(fake.workspacePanes?.contains { UUID(uuidString: $0.id) == sessionId } == false)
        #expect(repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == chatPaneId)
        #expect(repository.workspace(id: workspaceId)?.tabId(containingPane: placeholder.id) != nil)
        #expect(repository.workspace(id: workspaceId)?.isServerSynced == true)
        #expect(fake.workspaceSnapshotCallCount == 2)
    }

    @Test("A stale placeholder snapshot cannot repaint an optimistic chat promotion")
    func staleWorkspacePaneSnapshotDoesNotRevertPromotion() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let sessionId = UUID()
        let paneId = UUID()
        let project = ServerProject(
            id: projectId.uuidString,
            name: "Shared",
            isArchived: false,
            origin: .codevisor,
            createdAt: "2026-06-30T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: UUID().uuidString,
                    projectId: projectId.uuidString,
                    serverId: "local",
                    folderPath: "/tmp/stale-pane",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    isGitRepository: nil
                )
            ]
        )
        let session = ServerSession(
            id: sessionId.uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            harnessId: "codex",
            agentSessionId: nil,
            title: "New Chat",
            origin: .codevisor,
            isArchived: false,
            worktreeName: nil,
            workspaceId: workspaceId.uuidString,
            cwd: "/tmp/stale-pane",
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: nil,
            usage: nil
        )
        let workspaceRecord = ServerWorkspace(
            id: workspaceId.uuidString,
            serverId: "local",
            projectId: projectId.uuidString,
            name: "Shared",
            hasCustomName: false,
            rootDirectory: "/tmp/stale-pane",
            isArchived: false,
            createdAt: "2026-06-30T00:00:00.000Z"
        )
        let placeholderRecord = ServerWorkspacePane(
            id: paneId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "new-tab",
            title: "New tab",
            revision: 1,
            createdAt: "2026-06-30T00:00:02.000Z"
        )
        let fake = SyncFakeServerClient(
            projects: [project],
            sessions: [session],
            workspaces: [workspaceRecord],
            panes: [placeholderRecord]
        )
        fake.configurePanePromotionDelay(nanoseconds: 250_000_000)
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let placeholder = PaneDescriptorState(
            id: paneId,
            kind: .newTab,
            name: "New tab",
            terminalKey: paneId.uuidString
        )
        repository.save(
            Workspace(
                id: workspaceId,
                name: "Shared",
                rootDirectory: "/tmp/stale-pane",
                serverId: "local",
                projectId: projectId,
                centerTree: .leaf(
                    PaneGroupState(
                        panes: [placeholder], selectedPaneId: paneId, isVisible: true
                    )
                ),
                bottomGroup: PaneGroupState(),
                isServerSynced: true
            )
        )
        let workspaceSync = WorkspaceSyncModel(repository: repository, projectList: projectList)
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            workspaceSync: workspaceSync,
            clientFactory: { _ in fake }
        )
        await controller.refreshSelectedNavigationState()
        let localSession = try #require(projectList.sessions.first { $0.id == sessionId })
        let promoted = PaneDescriptorState(
            id: paneId,
            kind: .chat,
            name: "New Chat",
            terminalKey: paneId.uuidString,
            chatSessionId: sessionId
        )
        var localWorkspace = try #require(repository.workspace(id: workspaceId))
        localWorkspace.upsertCenterPane(promoted)
        repository.save(localWorkspace)

        workspaceSync.promotePaneToChat(
            promoted,
            session: localSession,
            workspaceId: workspaceId,
            client: fake
        )
        // This response is deliberately captured while the server still has
        // revision 1 / New Tab. It must not overwrite the local renderer.
        await workspaceSync.refreshFromServer(serverId: "local", client: fake)
        #expect(repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == paneId)

        try await waitForSync {
            fake.workspacePanes?.first?.paneType == "chat"
                && repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == paneId
        }
    }

    @Test("Optimistic pane closes reject stale snapshots and preserve the final pane id")
    func optimisticWorkspacePaneClose() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let firstId = UUID()
        let secondId = UUID()
        let workspaceRecord = ServerWorkspace(
            id: workspaceId.uuidString,
            serverId: "local",
            projectId: projectId.uuidString,
            name: "Shared",
            hasCustomName: false,
            rootDirectory: "/tmp/optimistic-close",
            isArchived: false,
            createdAt: "2026-06-30T00:00:00.000Z"
        )
        let firstRecord = ServerWorkspacePane(
            id: firstId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "terminal",
            title: "Terminal 1",
            resourceKind: "terminal",
            resourceId: "one",
            revision: 1,
            createdAt: "2026-06-30T00:00:01.000Z"
        )
        let secondRecord = ServerWorkspacePane(
            id: secondId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "terminal",
            title: "Terminal 2",
            resourceKind: "terminal",
            resourceId: "two",
            revision: 1,
            createdAt: "2026-06-30T00:00:02.000Z"
        )
        let fake = SyncFakeServerClient(
            projects: [], sessions: [], workspaces: [workspaceRecord],
            panes: [firstRecord, secondRecord]
        )
        fake.configurePaneCloseDelay(nanoseconds: 250_000_000)
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let first = PaneDescriptorState(
            id: firstId, kind: .terminal, name: "Terminal 1", terminalKey: "one"
        )
        let second = PaneDescriptorState(
            id: secondId, kind: .terminal, name: "Terminal 2", terminalKey: "two"
        )
        var local = Workspace(
            id: workspaceId,
            name: "Shared",
            rootDirectory: "/tmp/optimistic-close",
            serverId: "local",
            projectId: projectId,
            centerTabs: [
                WorkspaceTab(
                    root: .leaf(
                        PaneGroupState(panes: [first], selectedPaneId: firstId, isVisible: true)
                    )
                ),
                WorkspaceTab(
                    root: .leaf(
                        PaneGroupState(panes: [second], selectedPaneId: secondId, isVisible: true)
                    )
                ),
            ],
            bottomGroup: PaneGroupState(),
            isServerSynced: true
        )
        let sync = WorkspaceSyncModel(repository: repository, projectList: projectList)

        // The UI removes the second pane immediately. A snapshot captured
        // while Close is still in flight must not resurrect it.
        local.centerTabs.removeLast()
        local.selectedCenterTabId = local.centerTabs[0].id
        repository.save(local)
        sync.deletePane(id: secondId, workspaceId: workspaceId, client: fake)
        await sync.refreshFromServer(serverId: "local", client: fake)
        #expect(repository.workspace(id: workspaceId)?.tabId(containingPane: secondId) == nil)
        try await waitForSync {
            fake.workspacePanes?.contains(where: { UUID(uuidString: $0.id) == secondId }) == false
        }

        // Closing the remaining renderer is an in-place optimistic reset and
        // the server confirms that exact same identity.
        fake.configurePaneCloseDelay(nanoseconds: 0)
        var final = try #require(repository.workspace(id: workspaceId))
        let groupId = try #require(final.centerTabs[0].root.allGroups.first?.id)
        var replacement: PaneDescriptorState?
        final.centerTabs[0].root = final.centerTabs[0].root.updatingGroup(id: groupId) { state in
            var state = state
            replacement = state.replacePaneWithNewTab(id: firstId)
            return state
        }
        repository.save(final)
        sync.deletePane(
            id: firstId,
            workspaceId: workspaceId,
            optimisticReplacement: replacement,
            client: fake
        )
        #expect(repository.workspace(id: workspaceId)?.centerTree.allGroups[0].state.selectedPane?.id == firstId)
        try await waitForSync {
            fake.workspacePanes?.first?.id.caseInsensitiveCompare(firstId.uuidString) == .orderedSame
                && fake.workspacePanes?.first?.paneType == "new-tab"
                && repository.workspace(id: workspaceId)?.centerTree.allGroups[0].state.selectedPane?.kind
                    == .newTab
        }
    }

    @Test("An immediate pane close reaches the server after its create")
    func immediateWorkspacePaneClosePreservesCommandOrder() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let paneId = UUID()
        let workspaceRecord = ServerWorkspace(
            id: workspaceId.uuidString,
            serverId: "local",
            projectId: projectId.uuidString,
            name: "Shared",
            hasCustomName: false,
            rootDirectory: "/tmp/ordered-close",
            isArchived: false,
            createdAt: "2026-06-30T00:00:00.000Z"
        )
        let fake = SyncFakeServerClient(
            projects: [], sessions: [], workspaces: [workspaceRecord], panes: []
        )
        fake.configurePaneUpsertDelay(nanoseconds: 200_000_000)
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        let pane = PaneDescriptorState(
            id: paneId,
            kind: .newTab,
            name: "New tab",
            terminalKey: paneId.uuidString
        )
        repository.save(
            Workspace(
                id: workspaceId,
                name: "Shared",
                rootDirectory: "/tmp/ordered-close",
                serverId: "local",
                projectId: projectId,
                centerTree: .leaf(
                    PaneGroupState(panes: [pane], selectedPaneId: paneId, isVisible: true)
                ),
                bottomGroup: PaneGroupState(),
                isServerSynced: true
            )
        )
        let sync = WorkspaceSyncModel(repository: repository, projectList: projectList)

        sync.publishPane(pane, workspaceId: workspaceId, client: fake)
        sync.deletePane(
            id: paneId,
            workspaceId: workspaceId,
            optimisticReplacement: pane,
            client: fake
        )

        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.paneMutationLog == ["upsert"])
        try await waitForSync {
            fake.paneMutationLog == ["upsert", "close"]
                && fake.workspacePanes?.first?.id.caseInsensitiveCompare(paneId.uuidString)
                    == .orderedSame
        }
    }

    private func waitForSync(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for sync condition")
    }

    // The prepareSelectedMachine + LocalCodevisorServer integration tests
    // (rescan-on-already-running / no-rescan-on-fresh-launch) live in
    // CodevisorCoreMacTests/MachineControllerLocalServerTests.swift: they
    // construct the concrete macOS local server, which is no longer part of
    // this platform-neutral module.

    private func makeController(
        store: InMemoryStore = InMemoryStore()
    ) -> (
        controller: MachineController,
        projectList: ProjectListModel,
        store: InMemoryStore
    ) {
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(store: store, projectList: projectList)
        return (controller, projectList, store)
    }

}

private func sessionPayload(_ session: ServerSession) -> JSONValue {
    var payload: [String: JSONValue] = [
        "id": .string(session.id),
        "projectId": .string(session.projectId),
        "serverId": .string(session.serverId),
        "harnessId": .string(session.harnessId),
        "title": .string(session.title),
        "origin": .string(session.origin.rawValue),
        "isArchived": .bool(session.isArchived),
        "createdAt": .string(session.createdAt),
    ]
    if let agentSessionId = session.agentSessionId {
        payload["agentSessionId"] = .string(agentSessionId)
    }
    if let workspaceId = session.workspaceId {
        payload["workspaceId"] = .string(workspaceId)
    }
    if let worktreeName = session.worktreeName {
        payload["worktreeName"] = .string(worktreeName)
    }
    if let cwd = session.cwd {
        payload["cwd"] = .string(cwd)
    }
    if let updatedAt = session.updatedAt {
        payload["updatedAt"] = .string(updatedAt)
    }
    if let sidebarState = session.sidebarState {
        payload["sidebarState"] = .string(sidebarState.rawValue)
    }
    if let sidebarStateChangedAt = session.sidebarStateChangedAt {
        payload["sidebarStateChangedAt"] = .string(sidebarStateChangedAt)
    }
    return .object(payload)
}

/// Counts rescan calls; healthy by default so `ensureRunning` sees a durable
/// server, or unhealthy on the first probe to force a fresh launch.
private final class RescanCountingClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _rescans = 0
    private var _failNextHealth: Bool
    private var _bootId: String?
    /// When set, `info()` throws it — used to exercise add-time validation.
    let infoError: (any Error)?

    init(failFirstHealth: Bool = false, infoError: (any Error)? = nil) {
        _failNextHealth = failFirstHealth
        self.infoError = infoError
    }

    var rescans: Int { lock.withLock { _rescans } }

    struct HealthError: Error {}

    func acceptBoot(_ bootId: String) {
        lock.withLock { _bootId = bootId }
    }

    func health() async throws -> ServerHealth {
        let (failNow, bootId) = lock.withLock {
            let fail = _failNextHealth
            _failNextHealth = false
            return (fail, _bootId)
        }
        if failNow { throw HealthError() }
        return ServerHealth(
            ok: true,
            version: "0.1.0",
            database: "ready",
            bootId: bootId
        )
    }

    func info() async throws -> ServerInfo {
        if let infoError { throw infoError }
        return ServerInfo(
            id: "local", name: "Local", kind: "local", version: "0.1.0",
            platform: "darwin", bindHost: "127.0.0.1"
        )
    }

    func rescanHarnesses() async throws -> [ServerHarness] {
        lock.withLock { _rescans += 1 }
        return []
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        ServerUpdateInfo(
            currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
            channel: "stable", checkedAt: nil, migrationState: "idle"
        )
    }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func listProjects() async throws -> [ServerProject] { [] }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
    func requestShutdown() async throws {}
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

/// A fake server whose event stream and list endpoints are test-driven.
private final class SyncFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _projects: [ServerProject]
    private var _sessions: [ServerSession]
    private var _workspaces: [ServerWorkspace]
    private var _panes: [ServerWorkspacePane]?
    private var continuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
    private var emittedEvents: [ServerEventEnvelope] = []
    private var nextEventId = 1
    private var _listSessionCallCount = 0
    private var _workspaceSnapshotCallCount = 0
    private var _paneUpsertDelayNanoseconds: UInt64 = 0
    private var _panePromotionDelayNanoseconds: UInt64 = 0
    private var _paneCloseDelayNanoseconds: UInt64 = 0
    private var _paneMutationLog: [String] = []

    init(
        projects: [ServerProject],
        sessions: [ServerSession],
        workspaces: [ServerWorkspace] = [],
        panes: [ServerWorkspacePane]? = nil
    ) {
        _projects = projects
        _sessions = sessions
        _workspaces = workspaces
        _panes = panes
    }

    func setSessions(_ sessions: [ServerSession]) {
        lock.withLock { _sessions = sessions }
    }

    func setProjects(_ projects: [ServerProject]) {
        lock.withLock { _projects = projects }
    }

    func setWorkspaces(_ workspaces: [ServerWorkspace]) {
        lock.withLock { _workspaces = workspaces }
    }

    func setPanes(_ panes: [ServerWorkspacePane]) {
        lock.withLock { _panes = panes }
    }

    func configurePanePromotionDelay(nanoseconds: UInt64) {
        lock.withLock { _panePromotionDelayNanoseconds = nanoseconds }
    }

    func configurePaneUpsertDelay(nanoseconds: UInt64) {
        lock.withLock { _paneUpsertDelayNanoseconds = nanoseconds }
    }

    func configurePaneCloseDelay(nanoseconds: UInt64) {
        lock.withLock { _paneCloseDelayNanoseconds = nanoseconds }
    }

    var listSessionCallCount: Int { lock.withLock { _listSessionCallCount } }
    var workspaceSnapshotCallCount: Int { lock.withLock { _workspaceSnapshotCallCount } }
    var sessions: [ServerSession] { lock.withLock { _sessions } }
    var workspaces: [ServerWorkspace] { lock.withLock { _workspaces } }
    var workspacePanes: [ServerWorkspacePane]? { lock.withLock { _panes } }
    var paneMutationLog: [String] { lock.withLock { _paneMutationLog } }

    func emit(kind: String, subjectId: String, payload: JSONValue = .null) {
        let (event, targets):
            (ServerEventEnvelope, [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation]) = lock.withLock {
                let event = ServerEventEnvelope(
                    id: nextEventId,
                    serverId: "local",
                    kind: kind,
                    subjectId: subjectId,
                    createdAt: "2026-06-30T00:00:02.000Z",
                    payload: payload
                )
                nextEventId += 1
                emittedEvents.append(event)
                return (event, continuations)
            }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Mirrors the real server: replays the event log from `since`, then
    /// streams new events.
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            let backlog: [ServerEventEnvelope] = lock.withLock {
                continuations.append(continuation)
                return emittedEvents.filter { $0.id > since }
            }
            for event in backlog {
                continuation.yield(event)
            }
        }
    }

    func listProjects() async throws -> [ServerProject] { lock.withLock { _projects } }
    func listSessions() async throws -> [ServerSession] {
        lock.withLock {
            _listSessionCallCount += 1
            return _sessions
        }
    }
    func listWorkspaces() async throws -> [ServerWorkspace]? { lock.withLock { _workspaces } }
    func workspaceSnapshot() async throws -> ServerWorkspaceSnapshot? {
        lock.withLock {
            _workspaceSnapshotCallCount += 1
            guard let panes = _panes else { return nil }
            return ServerWorkspaceSnapshot(workspaces: _workspaces, panes: panes)
        }
    }
    func upsertWorkspace(_ workspace: ServerWorkspace) async throws -> ServerWorkspace? {
        lock.withLock {
            _workspaces.removeAll {
                $0.id.caseInsensitiveCompare(workspace.id) == .orderedSame
            }
            _workspaces.append(workspace)
            return workspace
        }
    }
    func listWorkspacePanes() async throws -> [ServerWorkspacePane]? { lock.withLock { _panes } }
    func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? {
        let delay = lock.withLock {
            _paneMutationLog.append("upsert")
            return _paneUpsertDelayNanoseconds
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return lock.withLock { () -> ServerWorkspacePane? in
            guard _panes != nil else { return nil }
            _panes?.removeAll { $0.id.caseInsensitiveCompare(pane.id) == .orderedSame }
            _panes?.append(pane)
            return pane
        }
    }

    func promoteWorkspacePaneToChat(
        _ pane: ServerWorkspacePane,
        session: ChatSession
    ) async throws -> ServerWorkspacePanePromotion? {
        let delay = lock.withLock { _panePromotionDelayNanoseconds }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return lock.withLock {
            guard
                let paneIndex = _panes?.firstIndex(where: {
                    $0.id.caseInsensitiveCompare(pane.id) == .orderedSame
                }),
                let sessionIndex = _sessions.firstIndex(where: {
                    UUID(uuidString: $0.id) == session.id
                })
            else { return nil }
            var promoted = pane
            promoted.revision = (_panes?[paneIndex].revision ?? 0) + 1
            _panes?[paneIndex] = promoted
            _sessions[sessionIndex].workspaceId = pane.workspaceId
            return ServerWorkspacePanePromotion(
                pane: promoted,
                session: _sessions[sessionIndex]
            )
        }
    }

    func deleteWorkspacePane(workspaceId _: UUID, paneId: UUID) async throws {
        lock.withLock {
            _panes?.removeAll {
                $0.id.caseInsensitiveCompare(paneId.uuidString) == .orderedSame
            }
        }
    }

    func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? {
        let delay = lock.withLock {
            _paneMutationLog.append("close")
            return _paneCloseDelayNanoseconds
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return lock.withLock { () -> ServerWorkspacePane? in
            guard let panes = _panes else { return nil }
            let workspacePaneIndices = panes.indices.filter {
                panes[$0].workspaceId.caseInsensitiveCompare(workspaceId.uuidString) == .orderedSame
            }
            guard
                let index = workspacePaneIndices.first(where: {
                    panes[$0].id.caseInsensitiveCompare(paneId.uuidString) == .orderedSame
                })
            else { return nil }
            if workspacePaneIndices.count > 1 {
                _panes?.remove(at: index)
                return nil
            }
            var replacement = panes[index]
            if replacement.paneType != "new-tab" || replacement.resourceId != nil {
                replacement.providerId = "codevisor"
                replacement.paneType = "new-tab"
                replacement.title = "New tab"
                replacement.resourceKind = nil
                replacement.resourceId = nil
                replacement.metadata = nil
                replacement.revision = (replacement.revision ?? 0) + 1
                _panes?[index] = replacement
            }
            return replacement
        }
    }

    // MARK: - Simulated server versioning / self-update

    private var currentVersion = "0.1.0"
    private var latestVersion = "0.1.0"
    private var installedVersionAfterUpdate: String?
    private var updateApplied = false
    private var bootId = "boot-before-update"
    private var downtimeRemaining = 0
    private var _appliedUpdates = 0
    private var _updateInfoChannels: [ServerUpdateChannel] = []
    private var _updateInfoRefreshes: [Bool] = []
    private var _appliedChannels: [ServerUpdateChannel] = []
    private var _busy = false

    struct ServerDownError: Error {}

    var appliedUpdates: Int { lock.withLock { _appliedUpdates } }
    var updateInfoChannels: [ServerUpdateChannel] { lock.withLock { _updateInfoChannels } }
    var updateInfoRefreshes: [Bool] { lock.withLock { _updateInfoRefreshes } }
    var appliedChannels: [ServerUpdateChannel] { lock.withLock { _appliedChannels } }

    /// Makes the fake report an available update to `latest`.
    func configureUpdate(current: String, latest: String, installedVersion: String? = nil) {
        lock.withLock {
            currentVersion = current
            latestVersion = latest
            installedVersionAfterUpdate = installedVersion
            updateApplied = false
            bootId = "boot-before-update"
        }
    }

    /// Makes `applyServerUpdate()` decline as busy (chats still running).
    func configureBusy(_ value: Bool) {
        lock.withLock { _busy = value }
    }

    func health() async throws -> ServerHealth {
        lock.withLock {
            ServerHealth(
                ok: true,
                version: currentVersion,
                database: "ready",
                bootId: bootId
            )
        }
    }
    func info() async throws -> ServerInfo {
        let version: String = try lock.withLock {
            if downtimeRemaining > 0 {
                downtimeRemaining -= 1
                throw ServerDownError()
            }
            return currentVersion
        }
        return ServerInfo(
            id: "local", name: "Local", kind: "local", version: version, platform: "darwin", bindHost: "127.0.0.1")
    }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        lock.withLock {
            _updateInfoChannels.append(channel)
            _updateInfoRefreshes.append(refresh)
            return ServerUpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                updateAvailable: !updateApplied && currentVersion != latestVersion,
                channel: channel.rawValue,
                checkedAt: nil,
                migrationState: "idle"
            )
        }
    }
    func applyServerUpdate(channel: ServerUpdateChannel) async throws -> ServerUpdateApplied {
        lock.withLock {
            _appliedChannels.append(channel)
            _appliedUpdates += 1
            if _busy {
                return ServerUpdateApplied(accepted: false, targetVersion: currentVersion, reason: "busy")
            }
            guard currentVersion != latestVersion else {
                return ServerUpdateApplied(accepted: false, targetVersion: currentVersion)
            }
            // The server restarts: unreachable for a few probes, then back on
            // the new version.
            downtimeRemaining = 3
            let targetVersion = latestVersion
            currentVersion = installedVersionAfterUpdate ?? latestVersion
            updateApplied = true
            bootId = "boot-after-update"
            return ServerUpdateApplied(accepted: true, targetVersion: targetVersion)
        }
    }
    func issuePairingToken() async throws -> ServerPairingToken {
        ServerPairingToken(token: "hm_test", createdAt: "2026-06-30T00:00:00.000Z")
    }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        lock.withLock {
            guard
                let index = _sessions.firstIndex(where: {
                    UUID(uuidString: $0.id) == session.id
                })
            else { fatalError("Missing fake session") }
            return _sessions[index]
        }
    }
    func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
        lock.withLock {
            guard
                let index = _sessions.firstIndex(where: {
                    UUID(uuidString: $0.id) == session.id
                })
            else { fatalError("Missing fake session") }
            _sessions[index].workspaceId = workspaceId?.uuidString
            if let workspaceId, _panes != nil,
                _panes?.contains(where: {
                    $0.resourceKind == "session"
                        && $0.resourceId?.caseInsensitiveCompare(session.id.uuidString) == .orderedSame
                }) == false
            {
                _panes?.append(
                    ServerWorkspacePane(
                        id: session.id.uuidString,
                        workspaceId: workspaceId.uuidString,
                        providerId: "codevisor",
                        paneType: "chat",
                        title: _sessions[index].title,
                        resourceKind: "session",
                        resourceId: session.id.uuidString,
                        createdAt: _sessions[index].createdAt
                    )
                )
            }
            return _sessions[index]
        }
    }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
