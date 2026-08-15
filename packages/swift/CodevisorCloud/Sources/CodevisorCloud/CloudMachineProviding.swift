import CodevisorClient
import Foundation

/// What the machine list needs from the cloud account feature: the signed-in
/// account's machines plus relay-backed server configs for them. Implemented
/// by CloudAccountController; fakes stand in for tests.
@MainActor
public protocol CloudMachineProviding: AnyObject {
    var isCloudSignedIn: Bool { get }
    var cloudMachines: [CloudMachine] { get }
    /// A server config whose transports tunnel through the cloud relay to
    /// this machine — nil when the relay isn't available (signed out).
    func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig?
    /// A real `http://127.0.0.1:<port>` base URL for this machine, served by
    /// an in-app loopback bridge that forwards plain HTTP/WebSocket onto the
    /// relay — for baseURL consumers that spawn external processes (the
    /// terminal proxy). Calling this may lazily start the bridge; nil until
    /// it is listening (or when the implementation doesn't bridge).
    func loopbackBaseURL(for machine: CloudMachine) -> URL?
    /// Registers the machine this app runs on with the signed-in account.
    /// Nudged from local status refreshes so a server that starts after
    /// sign-in still registers.
    func registerLocalMachineIfNeeded()
}

public extension CloudMachineProviding {
    func loopbackBaseURL(for machine: CloudMachine) -> URL? { nil }
    func registerLocalMachineIfNeeded() {}
}

extension CodevisorMachine {
    /// The machine-list entry for a cloud presence entry that has no
    /// configured (direct) machine. Its id is stable across launches because
    /// the cloud device id is.
    public static func cloud(from machine: CloudMachine) -> CodevisorMachine {
        CodevisorMachine(
            id: "\(cloudIdPrefix)\(machine.deviceId)",
            name: machine.name,
            baseURL: cloudPlaceholderBaseURL,
            kind: "cloud"
        )
    }
}
