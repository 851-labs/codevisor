import Foundation
import Observation

/// State of the app-managed local server. Lives in CodevisorCore (not
/// CodevisorCoreMac) because shared, platform-neutral code — `MachineController`
/// and status UI — renders it. Only macOS can *produce* most of these states;
/// on iOS there is no local server and `AppEnvironment.localServer` is nil.
public enum LocalCodevisorServerState: Equatable, Sendable {
    case idle
    case alreadyRunning
    case started
    case unavailable(String)
}

public struct LocalDataUpgradeProgress: Codable, Equatable, Sendable {
    public var state: String
    public var id: String
    public var name: String
    public var completed: Int
    public var total: Int
    public var error: String?
    public var bootId: String?
    public var pid: Int?
    public var updatedAt: String?

    public init(
        state: String,
        id: String,
        name: String,
        completed: Int,
        total: Int,
        error: String? = nil,
        bootId: String? = nil,
        pid: Int? = nil,
        updatedAt: String? = nil
    ) {
        self.state = state
        self.id = id
        self.name = name
        self.completed = completed
        self.total = total
        self.error = error
        self.bootId = bootId
        self.pid = pid
        self.updatedAt = updatedAt
    }

    public var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// Platform-owned lifecycle hooks. The macOS app supplies an SMAppService
/// LaunchAgent; tests and development omit it and keep the direct child path.
public struct LocalCodevisorManagedService {
    public var prepare: @MainActor () async throws -> Void
    public var start: @MainActor () async throws -> Void
    public var stop: @MainActor () async throws -> Void

    public init(
        prepare: @escaping @MainActor () async throws -> Void = {},
        start: @escaping @MainActor () async throws -> Void,
        stop: @escaping @MainActor () async throws -> Void
    ) {
        self.prepare = prepare
        self.start = start
        self.stop = stop
    }
}

/// The shared-facing surface of the app-managed local server. The concrete
/// implementation (`LocalCodevisorServer`, spawning the bundled Node runtime)
/// is macOS-only and lives in CodevisorCoreMac; shared code programs against
/// this protocol so `CodevisorCore` builds on platforms with no local server.
@MainActor
public protocol LocalServerControlling: AnyObject, Observable {
    var state: LocalCodevisorServerState { get }
    /// Sidecar progress remains available while the new server is performing
    /// its blocking migration and therefore cannot answer HTTP yet.
    var dataUpgradeProgress: LocalDataUpgradeProgress? { get }
    /// Invoked when the bundled server exits asking the app to take over the
    /// update; see `LocalCodevisorServer.onUpdateRequested`.
    var onUpdateRequested: (@MainActor () -> Void)? { get set }

    func configureManagedService(_ service: LocalCodevisorManagedService)
    @discardableResult
    func ensureRunning() async -> LocalCodevisorServerState
    /// Returns true when the server is stopped and ready for an app update.
    func prepareForAppUpdate() async -> Bool
    func shutdown() async -> Bool
}
