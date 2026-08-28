import Foundation
import Observation

/// One machine's harness catalog and mutations. Native views own presentation
/// (sheets, menus, layout); this model owns request ordering and server state.
@MainActor
@Observable
public final class HarnessMachineModel {
    public enum CatalogState: Equatable, Sendable {
        case initial
        case scanning
        case loaded
        case failed(String)
    }

    public struct OperationError: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let message: String

        public init(id: UUID = UUID(), title: String, message: String) {
            self.id = id
            self.title = title
            self.message = message
        }
    }

    public struct Dependencies {
        public typealias CatalogLoader = @MainActor () async throws -> [ServerHarness]
        public typealias PreferenceSetter = @MainActor (_ id: String, _ enabled: Bool) async throws -> ServerHarness
        public typealias UpdateStarter = @MainActor (_ id: String) async throws -> ServerHarnessOperationStarted

        public var loadCatalog: CatalogLoader
        public var rescanCatalog: CatalogLoader
        public var setDesiredEnabled: PreferenceSetter
        public var startUpdate: UpdateStarter
        public var catalogDidChange: @MainActor () -> Void
        public var lifecycleDidChange: @MainActor (_ lifecycle: ServerHarnessLifecycleState, _ id: String) -> Void

        public init(
            loadCatalog: @escaping CatalogLoader,
            rescanCatalog: @escaping CatalogLoader,
            setDesiredEnabled: @escaping PreferenceSetter,
            startUpdate: @escaping UpdateStarter,
            catalogDidChange: @escaping @MainActor () -> Void = {},
            lifecycleDidChange:
                @escaping @MainActor (
                    _ lifecycle: ServerHarnessLifecycleState,
                    _ id: String
                ) -> Void = { _, _ in }
        ) {
            self.loadCatalog = loadCatalog
            self.rescanCatalog = rescanCatalog
            self.setDesiredEnabled = setDesiredEnabled
            self.startUpdate = startUpdate
            self.catalogDidChange = catalogDidChange
            self.lifecycleDidChange = lifecycleDidChange
        }
    }

    public private(set) var harnesses: [ServerHarness] = []
    public private(set) var catalogState: CatalogState = .initial
    public private(set) var operationError: OperationError?

    @ObservationIgnored private var dependencies: Dependencies?
    @ObservationIgnored private var configuredServerId: String?
    @ObservationIgnored private var catalogRequestId: UUID?
    private var scanningRequestId: UUID?
    private var preferenceMutationIds: [String: UUID] = [:]
    private var startingUpdateIds: [String: UUID] = [:]

    public init() {}

    public var installedHarnesses: [ServerHarness] { harnesses.filter(\.isReady) }
    public var notInstalledHarnesses: [ServerHarness] { harnesses.filter { !$0.isReady } }

    public var isScanning: Bool {
        catalogState == .initial || scanningRequestId != nil
    }

    public var catalogErrorMessage: String? {
        guard case let .failed(message) = catalogState else { return nil }
        return message
    }

    public func configure(for serverId: String, dependencies: Dependencies) {
        self.dependencies = dependencies
        guard configuredServerId != serverId else { return }
        configuredServerId = serverId
        catalogRequestId = UUID()
        scanningRequestId = nil
        preferenceMutationIds = [:]
        startingUpdateIds = [:]
        harnesses = []
        catalogState = .initial
        operationError = nil
    }

    public func harness(id: String) -> ServerHarness? {
        harnesses.first { $0.id == id }
    }

    public func isChangingPreference(for id: String) -> Bool {
        preferenceMutationIds[id] != nil
    }

    public func isStartingUpdate(for id: String) -> Bool {
        startingUpdateIds[id] != nil
    }

    public func dismissOperationError() {
        operationError = nil
    }

    /// Re-resolves PATH and reloads the complete catalog. A newer scan or
    /// refresh always wins; failures retain the last useful catalog.
    @discardableResult
    public func scan() async -> ServerHarness? {
        guard let dependencies else { return nil }
        let requestId = UUID()
        catalogRequestId = requestId
        scanningRequestId = requestId
        catalogState = .scanning
        defer {
            if scanningRequestId == requestId {
                scanningRequestId = nil
            }
        }

        do {
            let next = try await dependencies.rescanCatalog()
            guard catalogRequestId == requestId else { return nil }
            let authenticationCandidate = applyCatalog(next)
            catalogState = .loaded
            dependencies.catalogDidChange()
            return authenticationCandidate
        } catch {
            guard catalogRequestId == requestId else { return nil }
            if error is CancellationError {
                catalogState = harnesses.isEmpty ? .initial : .loaded
            } else {
                catalogState = .failed(ErrorReporter.userFacingMessage(for: error))
            }
            return nil
        }
    }

    /// Event-driven light reload. It never supersedes an active user scan,
    /// while a subsequently started scan invalidates this request.
    @discardableResult
    public func refresh() async -> ServerHarness? {
        guard let dependencies, scanningRequestId == nil else { return nil }
        let requestId = UUID()
        catalogRequestId = requestId
        do {
            let next = try await dependencies.loadCatalog()
            guard catalogRequestId == requestId else { return nil }
            let authenticationCandidate = applyCatalog(next)
            catalogState = .loaded
            return authenticationCandidate
        } catch {
            guard catalogRequestId == requestId else { return nil }
            if harnesses.isEmpty, !(error is CancellationError) {
                catalogState = .failed(ErrorReporter.userFacingMessage(for: error))
            }
            return nil
        }
    }

    public func replaceHarness(_ harness: ServerHarness) {
        guard let index = harnesses.firstIndex(where: { $0.id == harness.id }) else { return }
        harnesses[index] = harness
    }

    public func replaceCatalog(_ harnesses: [ServerHarness], notifying: Bool = false) {
        // An editor save is authoritative over any catalog request that was
        // already in flight when the sheet opened.
        catalogRequestId = UUID()
        scanningRequestId = nil
        self.harnesses = harnesses
        catalogState = .loaded
        if notifying {
            dependencies?.catalogDidChange()
        }
    }

    public func setDesiredEnabled(id: String, enabled: Bool) async {
        guard let dependencies,
            preferenceMutationIds[id] == nil,
            let previous = harness(id: id)
        else { return }

        let mutationId = UUID()
        preferenceMutationIds[id] = mutationId
        operationError = nil
        updateDesiredEnabled(id: id, enabled: enabled)
        defer {
            if preferenceMutationIds[id] == mutationId {
                preferenceMutationIds[id] = nil
            }
        }

        do {
            let updated = try await dependencies.setDesiredEnabled(id, enabled)
            guard preferenceMutationIds[id] == mutationId else { return }
            replaceHarness(updated)
            dependencies.catalogDidChange()
        } catch {
            guard preferenceMutationIds[id] == mutationId else { return }
            updateDesiredEnabled(id: id, enabled: previous.isDesiredEnabled)
            let name = harness(id: id)?.name ?? previous.name
            operationError = OperationError(
                title: enabled ? "Couldn't turn on \(name)" : "Couldn't turn off \(name)",
                message: ErrorReporter.userFacingMessage(for: error)
            )
        }
    }

    public func updateHarness(id: String) async {
        guard let dependencies,
            startingUpdateIds[id] == nil,
            let harness = harness(id: id)
        else { return }

        let updateId = UUID()
        startingUpdateIds[id] = updateId
        operationError = nil
        defer {
            if startingUpdateIds[id] == updateId {
                startingUpdateIds[id] = nil
            }
        }

        do {
            let started = try await dependencies.startUpdate(id)
            guard startingUpdateIds[id] == updateId else { return }
            if let lifecycle = started.lifecycle,
                let index = harnesses.firstIndex(where: { $0.id == id })
            {
                harnesses[index].lifecycle = lifecycle
                dependencies.lifecycleDidChange(lifecycle, id)
            } else {
                // Older servers omit lifecycle from the acknowledgement.
                _ = await refresh()
            }
            dependencies.catalogDidChange()
        } catch {
            guard startingUpdateIds[id] == updateId else { return }
            operationError = OperationError(
                title: "Couldn't update \(harness.name)",
                message: ErrorReporter.userFacingMessage(for: error)
            )
        }
    }

    private func updateDesiredEnabled(id: String, enabled: Bool) {
        guard let index = harnesses.firstIndex(where: { $0.id == id }) else { return }
        harnesses[index].desiredEnabled = enabled
    }

    @discardableResult
    private func applyCatalog(_ next: [ServerHarness]) -> ServerHarness? {
        let previous = harnesses
        harnesses = next
        return Self.newlyInstalledHarnessRequiringAuthentication(
            previous: previous,
            current: next
        )
    }

    public static func newlyInstalledHarnessRequiringAuthentication(
        previous: [ServerHarness],
        current: [ServerHarness]
    ) -> ServerHarness? {
        for harness in current where harness.isReady && harness.requiresAuthentication {
            let before = previous.first { $0.id == harness.id }
            if before?.lifecycle?.resolvedPhase == .installing, before?.isReady != true {
                return harness
            }
        }
        return nil
    }
}
