import Foundation
import Observation

public enum MachineControllerError: Error, Equatable, Sendable, LocalizedError {
    case invalidHost(String)
    case cannotRemoveLocal
    case cannotRenameLocal

    public var errorDescription: String? {
        switch self {
        case let .invalidHost(host):
            "“\(host)” isn't a valid host. Enter a hostname or IP address, like 192.168.1.20 or mac-studio.local."
        case .cannotRemoveLocal:
            "This Mac can't be removed from the machine list."
        case .cannotRenameLocal:
            "This Mac can't be renamed here. Its name follows the computer name in System Settings."
        }
    }
}

/// User-chosen SF Symbol used to identify a machine.
public struct MachineAppearance: Sendable, Codable, Equatable {
    public var symbolName: String

    public init(symbolName: String) {
        self.symbolName = symbolName
    }

    public static let localDefault = MachineAppearance(
        symbolName: "desktopcomputer"
    )

    public static let remoteDefault = MachineAppearance(
        symbolName: "network"
    )
}

public struct CodevisorMachine: Identifiable, Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var kind: String
    /// Bearer token for this machine's server. Nil for the local machine —
    /// same-machine connections are exempt from the server's token auth.
    public var token: String?
    /// Nil means the machine uses the appropriate local or remote default.
    /// Keeping this optional makes existing persisted registries decode
    /// without a migration.
    public var appearance: MachineAppearance?

    public init(
        id: String,
        name: String,
        baseURL: URL,
        kind: String,
        token: String? = nil,
        appearance: MachineAppearance? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.token = token
        self.appearance = appearance
    }

    public var isLocal: Bool { id == Self.local.id }

    public var resolvedAppearance: MachineAppearance {
        let fallback = isLocal ? MachineAppearance.localDefault : .remoteDefault
        guard let appearance,
              !appearance.symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return appearance
    }

    public var serverConfig: CodevisorServerConfig {
        CodevisorServerConfig(baseURL: baseURL, bearerToken: token)
    }

    public static let local = CodevisorMachine(
        id: "local",
        name: "Local",
        baseURL: URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
        kind: "local"
    )
}

public struct MachineRegistry: Sendable, Codable, Equatable {
    public var selectedMachineId: String
    public var remoteMachines: [CodevisorMachine]
    /// The local machine isn't stored in `remoteMachines`, so its optional
    /// appearance override lives alongside the remote registry.
    public var localAppearance: MachineAppearance?

    public init(
        selectedMachineId: String = CodevisorMachine.local.id,
        remoteMachines: [CodevisorMachine] = [],
        localAppearance: MachineAppearance? = nil
    ) {
        self.selectedMachineId = selectedMachineId
        self.remoteMachines = remoteMachines
        self.localAppearance = localAppearance
    }
}

public struct MachineStatus: Sendable, Equatable {
    public var isReachable: Bool
    public var label: String
}

/// Progress of a client-triggered update of the selected machine's server.
public enum ServerUpdatePhase: Equatable, Sendable {
    case idle
    case updating
    case failed(String)
}

@MainActor
@Observable
public final class MachineController {
    public private(set) var registry: MachineRegistry
    public private(set) var statusByMachineId: [String: MachineStatus] = [:]
    public private(set) var updateInfoByMachineId: [String: ServerUpdateInfo] = [:]
    public private(set) var serverUpdatePhase: ServerUpdatePhase = .idle

    public typealias ClientFactory = @MainActor (CodevisorMachine) -> any CodevisorServerClienting

    private let store: any PersistenceStore
    private let projectList: ProjectListModel
    private let localServer: LocalCodevisorServer?
    private let clientFactory: ClientFactory
    private let key = "machines"
    /// How long to wait between reachability probes while the remote server
    /// restarts into its updated version. Injectable so tests run fast.
    private let updatePollInterval: Duration
    private let updatePollAttempts: Int
    @ObservationIgnored private var eventSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?

    public init(
        store: any PersistenceStore,
        projectList: ProjectListModel,
        localServer: LocalCodevisorServer? = nil,
        clientFactory: ClientFactory? = nil,
        updatePollInterval: Duration = .seconds(2),
        updatePollAttempts: Int = 90
    ) {
        self.store = store
        self.projectList = projectList
        self.localServer = localServer
        self.clientFactory = clientFactory ?? { CodevisorServerClient(config: $0.serverConfig) }
        self.updatePollInterval = updatePollInterval
        self.updatePollAttempts = updatePollAttempts
        if let data = store.loadData(forKey: "machines") {
            do {
                registry = try JSONDecoder().decode(MachineRegistry.self, from: data).normalized()
            } catch {
                registry = MachineRegistry()
                handleCorruptPayload(
                    store: store,
                    key: "machines",
                    data: data,
                    error: error,
                    reportTitle: "Couldn't Read Your Machine List",
                    reportMessage: "The file was unreadable. A backup was saved in Codevisor's data folder."
                )
            }
        } else {
            registry = MachineRegistry()
        }
        projectList.selectServer(
            serverId: selectedMachine.id,
            serverClient: selectedClient,
            refresh: false
        )
    }

    public var machines: [CodevisorMachine] {
        var local = CodevisorMachine.local
        local.appearance = registry.localAppearance
        return [local] + registry.remoteMachines
    }

    public var selectedMachineId: String {
        registry.selectedMachineId
    }

    public var selectedMachine: CodevisorMachine {
        machine(for: registry.selectedMachineId) ?? CodevisorMachine.local
    }

    public var selectedClient: any CodevisorServerClienting {
        client(for: selectedMachine.id)
    }

    public func machine(for id: String) -> CodevisorMachine? {
        machines.first { $0.id == id }
    }

    public func client(for machineId: String) -> any CodevisorServerClienting {
        let machine = machine(for: machineId) ?? CodevisorMachine.local
        return clientFactory(machine)
    }

    public func selectMachine(_ id: String) {
        guard let machine = machine(for: id) else { return }
        registry.selectedMachineId = machine.id
        persist()
        projectList.selectServer(serverId: machine.id, serverClient: client(for: machine.id))
    }

    @discardableResult
    public func addRemote(host input: String, name: String? = nil, token: String? = nil) throws -> CodevisorMachine {
        let baseURL = try Self.normalizedRemoteURL(from: input)
        let customName = Self.normalizedName(name)
        let normalizedToken = Self.normalizedName(token)
        if let index = registry.remoteMachines.firstIndex(where: { $0.baseURL == baseURL }) {
            if let customName {
                registry.remoteMachines[index].name = customName
            }
            if let normalizedToken {
                registry.remoteMachines[index].token = normalizedToken
            }
            let existing = registry.remoteMachines[index]
            registry.selectedMachineId = existing.id
            persist()
            projectList.selectServer(serverId: existing.id, serverClient: client(for: existing.id))
            Task { await refreshStatus(for: existing.id) }
            return existing
        }
        let baseId = Self.remoteId(for: baseURL)
        let id = uniqueMachineId(baseId)
        let machine = CodevisorMachine(
            id: id,
            name: customName ?? baseURL.host ?? id,
            baseURL: baseURL,
            kind: "remote",
            token: normalizedToken
        )
        registry.remoteMachines.append(machine)
        registry.selectedMachineId = machine.id
        persist()
        projectList.selectServer(serverId: machine.id, serverClient: client(for: machine.id))
        // Probe right away so a freshly added machine shows its real status
        // instead of waiting for the next periodic refresh.
        Task { await refreshStatus(for: machine.id) }
        return machine
    }

    /// This machine's stable connection token (the loopback call is exempt
    /// from token auth), for pasting into another device's Add Remote Machine
    /// sheet. Stable across restarts so the copied value keeps working.
    public func issueLocalConnectionToken() async throws -> String {
        try await client(for: CodevisorMachine.local.id).connectionToken().token
    }

    /// Adds a remote machine only after confirming the host is reachable and
    /// the token is accepted, so a wrong token surfaces as an error in the Add
    /// dialog instead of a broken machine you have to remove and re-add.
    @discardableResult
    public func addRemoteValidating(
        host input: String,
        name: String? = nil,
        token: String? = nil
    ) async throws -> CodevisorMachine {
        let baseURL = try Self.normalizedRemoteURL(from: input)
        let probe = CodevisorMachine(
            id: "probe",
            name: "probe",
            baseURL: baseURL,
            kind: "remote",
            token: Self.normalizedName(token)
        )
        // Throws on an unreachable host or a rejected token (401).
        _ = try await clientFactory(probe).info()
        return try addRemote(host: input, name: name, token: token)
    }

    /// Renames a remote machine. Blank names are ignored; the local machine
    /// can't be renamed.
    public func renameMachine(_ id: String, to name: String) throws {
        guard id != CodevisorMachine.local.id else { throw MachineControllerError.cannotRenameLocal }
        guard let customName = Self.normalizedName(name),
              let index = registry.remoteMachines.firstIndex(where: { $0.id == id })
        else { return }
        registry.remoteMachines[index].name = customName
        persist()
    }

    /// Updates the icon used to identify a machine throughout the app.
    /// Invalid values fall back to that machine kind's safe default.
    public func setAppearance(_ appearance: MachineAppearance, for id: String) {
        guard let machine = machine(for: id) else { return }
        let normalized = CodevisorMachine(
            id: machine.id,
            name: machine.name,
            baseURL: machine.baseURL,
            kind: machine.kind,
            token: machine.token,
            appearance: appearance
        ).resolvedAppearance

        if machine.isLocal {
            registry.localAppearance = normalized
        } else if let index = registry.remoteMachines.firstIndex(where: { $0.id == id }) {
            registry.remoteMachines[index].appearance = normalized
        }
        persist()
    }

    private static func normalizedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func removeMachine(_ id: String) throws {
        guard id != CodevisorMachine.local.id else { throw MachineControllerError.cannotRemoveLocal }
        registry.remoteMachines.removeAll { $0.id == id }
        if registry.selectedMachineId == id {
            registry.selectedMachineId = CodevisorMachine.local.id
            projectList.selectServer(serverId: CodevisorMachine.local.id, serverClient: selectedClient)
        }
        persist()
    }

    public func prepareSelectedMachine() async {
        if selectedMachine.isLocal {
            let serverState = await localServer?.ensureRunning()
            if serverState == .alreadyRunning {
                // The durable server's PATH is frozen at its launch; a CLI
                // installed since then (followed by an app relaunch) stays
                // invisible to it. Fire one rescan so it re-resolves PATH —
                // off the critical path so machine prep isn't delayed.
                let client = selectedClient
                Task {
                    do {
                        _ = try await client.rescanHarnesses()
                    } catch {
                        Log.machines.error("Harness rescan failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
        await refreshStatus(for: selectedMachine.id)
        await projectList.refreshFromServer()
        startEventSync()
    }

    // MARK: - Live sync

    /// Follows the selected server's event stream so projects and sessions
    /// stay in sync across every client connected to that server. Replaces any
    /// previous subscription (e.g. after switching machines).
    public func startEventSync() {
        eventSyncTask?.cancel()
        let serverId = selectedMachine.id
        let client = selectedClient
        eventSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // The project/session lists above are the shell snapshot.
                    // Subscribe live-only after it instead of replaying the
                    // server's lifetime global log on every app launch.
                    for try await event in client.shellEventStream() {
                        guard let self, !Task.isCancelled else { return }
                        self.handleSyncEvent(event, serverId: serverId)
                    }
                    return
                } catch {
                    Log.machines.error("Event sync for \(serverId, privacy: .public) failed; resubscribing: \(String(describing: error), privacy: .public)")
                    guard let self, !Task.isCancelled else { return }
                    // Reconcile durable metadata, then subscribe live-only
                    // again. This skips a malformed event instead of retrying
                    // forever from the same global cursor.
                    await self.projectList.refreshFromServer()
                }
            }
        }
    }

    public func stopEventSync() {
        eventSyncTask?.cancel()
        eventSyncTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    private func handleSyncEvent(_ event: ServerEventEnvelope, serverId: String) {
        guard serverId == selectedMachine.id else { return }
        switch event.kind {
        case "project.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                projectList.removeProjectLocally(id: id, serverId: serverId)
            }
        case "session.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                projectList.removeSessionLocally(id: id, serverId: serverId)
            }
        case "project.created", "project.updated", "worktree.created",
             "session.created", "session.updated", "session.archived":
            scheduleProjectRefresh()
        default:
            // Prompt/queue/error events are handled by the session transports.
            break
        }
    }

    /// Coalesces bursts of events (including the initial replay) into a single
    /// refresh from the server.
    private func scheduleProjectRefresh() {
        guard pendingRefreshTask == nil else { return }
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.pendingRefreshTask = nil
            await self.projectList.refreshFromServer()
        }
    }

    public func refreshStatus(for id: String) async {
        let client = client(for: id)
        do {
            let info = try await client.info()
            statusByMachineId[id] = MachineStatus(isReachable: true, label: "\(info.name) \(info.version)")
            do {
                updateInfoByMachineId[id] = try await client.updateInfo()
            } catch {
                updateInfoByMachineId[id] = nil
                Log.machines.debug("Update info probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        } catch {
            // A local server that failed to start has a more useful story
            // than "Unreachable" — surface why instead.
            if id == CodevisorMachine.local.id, case let .unavailable(message) = localServer?.state {
                statusByMachineId[id] = MachineStatus(isReachable: false, label: message)
            } else if case CodevisorServerClientError.httpStatus(401, _) = error {
                // The server answered — the token is just wrong (or the
                // machine was paired against a different server on that host).
                // Say so, so the user fixes the token instead of chasing a
                // phantom network problem.
                statusByMachineId[id] = MachineStatus(isReachable: false, label: "Invalid connection token")
            } else {
                statusByMachineId[id] = MachineStatus(isReachable: false, label: "Unreachable")
                Log.machines.debug("Status probe for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The selected machine's server update state, when known.
    public var selectedServerUpdate: ServerUpdateInfo? {
        updateInfoByMachineId[selectedMachineId]
    }

    /// Asks the selected machine's server to update itself, then waits for it
    /// to restart into the newer version before refreshing everything and
    /// resubscribing to its event stream.
    public func updateSelectedServer() async {
        guard serverUpdatePhase != .updating else { return }
        let machineId = selectedMachineId
        let client = selectedClient
        serverUpdatePhase = .updating
        do {
            let applied = try await client.applyServerUpdate()
            guard applied.accepted else {
                if applied.reason == "busy" {
                    // The server still has chats mid-turn; updating now would
                    // kill them. The banner disables its button for this app's
                    // own chats, but another client could have started one.
                    serverUpdatePhase = .failed(
                        "This server still has chats running. Wait for them to finish, then update."
                    )
                    return
                }
                // Nothing to do (already up to date); refresh the banner state.
                await refreshStatus(for: machineId)
                serverUpdatePhase = .idle
                return
            }
            for _ in 0..<updatePollAttempts {
                try? await Task.sleep(for: updatePollInterval)
                // The user moved on to a different machine; stop waiting.
                guard machineId == selectedMachineId else {
                    serverUpdatePhase = .idle
                    return
                }
                guard let info = try? await client.info() else { continue }
                if applied.targetVersion == nil || info.version == applied.targetVersion {
                    await refreshStatus(for: machineId)
                    await projectList.refreshFromServer()
                    startEventSync()
                    serverUpdatePhase = .idle
                    return
                }
            }
            serverUpdatePhase = .failed("The server did not come back after updating. Check it on the machine directly.")
        } catch {
            serverUpdatePhase = .failed(String(describing: error))
        }
    }

    public static func normalizedRemoteURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MachineControllerError.invalidHost(input) }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              components.host?.isEmpty == false else {
            throw MachineControllerError.invalidHost(input)
        }
        if components.scheme == nil {
            components.scheme = "http"
        }
        if components.port == nil {
            components.port = CodevisorServerConfig.productionPort
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw MachineControllerError.invalidHost(input) }
        return url
    }

    private func uniqueMachineId(_ baseId: String) -> String {
        if machine(for: baseId) == nil { return baseId }
        var index = 2
        while machine(for: "\(baseId)-\(index)") != nil {
            index += 1
        }
        return "\(baseId)-\(index)"
    }

    private static func remoteId(for url: URL) -> String {
        let host = url.host ?? "remote"
        let port = url.port ?? CodevisorServerConfig.productionPort
        let raw = "remote-\(host)-\(port)".lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(registry.normalized()), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

private extension MachineRegistry {
    func normalized() -> MachineRegistry {
        let remotes = remoteMachines.filter { !$0.isLocal }
        let allIds = Set(remotes.map(\.id)).union([CodevisorMachine.local.id])
        return MachineRegistry(
            selectedMachineId: allIds.contains(selectedMachineId) ? selectedMachineId : CodevisorMachine.local.id,
            remoteMachines: remotes,
            localAppearance: localAppearance
        )
    }
}
