import Foundation
import Observation

public enum MachineControllerError: Error, Equatable, Sendable {
    case invalidHost(String)
    case cannotRemoveLocal
    case cannotRenameLocal
}

public struct HerdManMachine: Identifiable, Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var kind: String

    public init(id: String, name: String, baseURL: URL, kind: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
    }

    public var isLocal: Bool { id == Self.local.id }

    public var serverConfig: HerdManServerConfig {
        HerdManServerConfig(baseURL: baseURL)
    }

    public static let local = HerdManMachine(
        id: "local",
        name: "Local",
        baseURL: URL(string: "http://127.0.0.1:\(HerdManServerConfig.localPort)")!,
        kind: "local"
    )
}

public struct MachineRegistry: Sendable, Codable, Equatable {
    public var selectedMachineId: String
    public var remoteMachines: [HerdManMachine]

    public init(selectedMachineId: String = HerdManMachine.local.id, remoteMachines: [HerdManMachine] = []) {
        self.selectedMachineId = selectedMachineId
        self.remoteMachines = remoteMachines
    }
}

public struct MachineStatus: Sendable, Equatable {
    public var isReachable: Bool
    public var label: String
}

@MainActor
@Observable
public final class MachineController {
    public private(set) var registry: MachineRegistry
    public private(set) var statusByMachineId: [String: MachineStatus] = [:]

    public typealias ClientFactory = @MainActor (HerdManMachine) -> any HerdManServerClienting

    private let store: any PersistenceStore
    private let workspaceList: WorkspaceListModel
    private let localServer: LocalHerdManServer?
    private let clientFactory: ClientFactory
    private let key = "machines"
    @ObservationIgnored private var eventSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?

    public init(
        store: any PersistenceStore,
        workspaceList: WorkspaceListModel,
        localServer: LocalHerdManServer? = nil,
        clientFactory: ClientFactory? = nil
    ) {
        self.store = store
        self.workspaceList = workspaceList
        self.localServer = localServer
        self.clientFactory = clientFactory ?? { HerdManServerClient(config: $0.serverConfig) }
        if let data = store.loadData(forKey: key),
           let decoded = try? JSONDecoder().decode(MachineRegistry.self, from: data) {
            registry = decoded.normalized()
        } else {
            registry = MachineRegistry()
        }
        workspaceList.selectServer(
            serverId: selectedMachine.id,
            serverClient: selectedClient,
            refresh: false
        )
    }

    public var machines: [HerdManMachine] {
        [HerdManMachine.local] + registry.remoteMachines
    }

    public var selectedMachineId: String {
        registry.selectedMachineId
    }

    public var selectedMachine: HerdManMachine {
        machine(for: registry.selectedMachineId) ?? HerdManMachine.local
    }

    public var selectedClient: any HerdManServerClienting {
        client(for: selectedMachine.id)
    }

    public func machine(for id: String) -> HerdManMachine? {
        machines.first { $0.id == id }
    }

    public func client(for machineId: String) -> any HerdManServerClienting {
        let machine = machine(for: machineId) ?? HerdManMachine.local
        return clientFactory(machine)
    }

    public func selectMachine(_ id: String) {
        guard let machine = machine(for: id) else { return }
        registry.selectedMachineId = machine.id
        persist()
        workspaceList.selectServer(serverId: machine.id, serverClient: client(for: machine.id))
    }

    @discardableResult
    public func addRemote(host input: String, name: String? = nil) throws -> HerdManMachine {
        let baseURL = try Self.normalizedRemoteURL(from: input)
        let customName = Self.normalizedName(name)
        if let index = registry.remoteMachines.firstIndex(where: { $0.baseURL == baseURL }) {
            if let customName {
                registry.remoteMachines[index].name = customName
            }
            let existing = registry.remoteMachines[index]
            registry.selectedMachineId = existing.id
            persist()
            workspaceList.selectServer(serverId: existing.id, serverClient: client(for: existing.id))
            return existing
        }
        let baseId = Self.remoteId(for: baseURL)
        let id = uniqueMachineId(baseId)
        let machine = HerdManMachine(
            id: id,
            name: customName ?? baseURL.host ?? id,
            baseURL: baseURL,
            kind: "remote"
        )
        registry.remoteMachines.append(machine)
        registry.selectedMachineId = machine.id
        persist()
        workspaceList.selectServer(serverId: machine.id, serverClient: client(for: machine.id))
        return machine
    }

    /// Renames a remote machine. Blank names are ignored; the local machine
    /// can't be renamed.
    public func renameMachine(_ id: String, to name: String) throws {
        guard id != HerdManMachine.local.id else { throw MachineControllerError.cannotRenameLocal }
        guard let customName = Self.normalizedName(name),
              let index = registry.remoteMachines.firstIndex(where: { $0.id == id })
        else { return }
        registry.remoteMachines[index].name = customName
        persist()
    }

    private static func normalizedName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func removeMachine(_ id: String) throws {
        guard id != HerdManMachine.local.id else { throw MachineControllerError.cannotRemoveLocal }
        registry.remoteMachines.removeAll { $0.id == id }
        if registry.selectedMachineId == id {
            registry.selectedMachineId = HerdManMachine.local.id
            workspaceList.selectServer(serverId: HerdManMachine.local.id, serverClient: selectedClient)
        }
        persist()
    }

    public func prepareSelectedMachine() async {
        if selectedMachine.isLocal {
            _ = await localServer?.ensureRunning()
        }
        await refreshStatus(for: selectedMachine.id)
        await workspaceList.refreshFromServer()
        startEventSync()
    }

    // MARK: - Live sync

    /// Follows the selected server's event stream so workspaces and sessions
    /// stay in sync across every client connected to that server. Replaces any
    /// previous subscription (e.g. after switching machines).
    public func startEventSync() {
        eventSyncTask?.cancel()
        let serverId = selectedMachine.id
        let client = selectedClient
        eventSyncTask = Task { [weak self] in
            do {
                for try await event in client.eventStream(since: 0) {
                    guard let self, !Task.isCancelled else { return }
                    self.handleSyncEvent(event, serverId: serverId)
                }
            } catch {
                // The stream reconnects internally; it only ends on cancellation.
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
        case "workspace.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                workspaceList.removeWorkspaceLocally(id: id)
            }
        case "session.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                workspaceList.removeSessionLocally(id: id)
            }
        case "workspace.created", "workspace.updated",
             "session.created", "session.updated", "session.archived":
            scheduleWorkspaceRefresh()
        default:
            // Prompt/queue/error events are handled by the session transports.
            break
        }
    }

    /// Coalesces bursts of events (including the initial replay) into a single
    /// refresh from the server.
    private func scheduleWorkspaceRefresh() {
        guard pendingRefreshTask == nil else { return }
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.pendingRefreshTask = nil
            await self.workspaceList.refreshFromServer()
        }
    }

    public func refreshStatus(for id: String) async {
        let client = client(for: id)
        do {
            let info = try await client.info()
            statusByMachineId[id] = MachineStatus(isReachable: true, label: "\(info.name) \(info.version)")
        } catch {
            statusByMachineId[id] = MachineStatus(isReachable: false, label: "Unreachable")
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
            components.port = HerdManServerConfig.productionPort
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
        let port = url.port ?? HerdManServerConfig.productionPort
        let raw = "remote-\(host)-\(port)".lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(registry.normalized()) else { return }
        try? store.saveData(data, forKey: key)
    }
}

private extension MachineRegistry {
    func normalized() -> MachineRegistry {
        let remotes = remoteMachines.filter { !$0.isLocal }
        let allIds = Set(remotes.map(\.id)).union([HerdManMachine.local.id])
        return MachineRegistry(
            selectedMachineId: allIds.contains(selectedMachineId) ? selectedMachineId : HerdManMachine.local.id,
            remoteMachines: remotes
        )
    }
}
