import CodevisorClient
import Foundation
import Observation

/// Finds and keeps direct LAN pipes to the account's machines. After each
/// machine refresh the account controller hands over the online machines
/// whose keys match their TOFU pins; for each one without a live pipe this
/// asks the machine — over the relay — where it can be reached
/// (`/v1/net/direct`), then probes those addresses and keeps the first pipe
/// that survives a sealed round trip (a welcome only proves something is
/// listening; the round trip proves it holds the pinned machine key).
///
/// The relay remains the source of truth for presence and the always-there
/// fallback: when a direct pipe dies its channels fail and consumers re-open
/// over whatever `SwitchingChannelTransport` picks next.
@MainActor
@Observable
public final class CloudDirectPathController {
    /// The machine's answer to GET /v1/net/direct.
    public struct Discovery: Codable, Sendable {
        public var deviceId: String?
        public var port: Int
        public var hosts: [String]

        public init(deviceId: String?, port: Int, hosts: [String]) {
            self.deviceId = deviceId
            self.port = port
            self.hosts = hosts
        }
    }

    /// Discovers, connects, and verifies one machine's direct pipe (nil when
    /// no address answers). Injectable so tests can script the whole probe.
    /// The third argument is the pipe's `onDown` callback.
    public typealias Prober =
        @Sendable (
            CloudMachine,
            any CloudChannelTransport,
            @escaping @Sendable () -> Void
        ) async -> CloudDirectConnection?

    /// Machines currently reachable over a verified direct pipe — the UI's
    /// "Direct" badge and the switching transports read this.
    public private(set) var machineIds: Set<String> = []

    @ObservationIgnored private var connections: [String: (connection: CloudDirectConnection, publicKey: String)] = [:]
    @ObservationIgnored var probeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastAttempt: [String: ContinuousClock.Instant] = [:]
    private let prober: Prober
    private let reprobeInterval: Duration

    public init(
        credentialStore: any CloudCredentialStore,
        webSocketTransport: any ServerWebSocketTransport = URLSessionWebSocketTransport(),
        reprobeInterval: Duration = .seconds(60),
        prober: Prober? = nil
    ) {
        self.reprobeInterval = reprobeInterval
        self.prober =
            prober
            ?? Self.defaultProber(
                credentialStore: credentialStore,
                webSocketTransport: webSocketTransport
            )
    }

    /// Reconciles the pipes against the current (verified-key, online)
    /// machine list: gone machines lose their pipe, unprobed ones get a
    /// throttled probe. `relayTransport` supplies the relay pipe used for
    /// discovery.
    public func reconcile(
        machines: [CloudMachine],
        relayTransport: (CloudMachine) -> any CloudChannelTransport
    ) {
        let known = Set(machines.map(\.deviceId))
        for deviceId in connections.keys where !known.contains(deviceId) {
            drop(deviceId: deviceId)
        }
        for machine in machines {
            if let existing = connections[machine.deviceId] {
                // A re-provisioned machine (fresh keys, same device id) needs
                // a fresh pipe — the old one seals toward the old key.
                guard existing.publicKey != machine.publicKey else { continue }
                drop(deviceId: machine.deviceId)
            }
            guard probeTasks[machine.deviceId] == nil else { continue }
            if let last = lastAttempt[machine.deviceId],
                last.duration(to: .now) < reprobeInterval
            {
                continue
            }
            lastAttempt[machine.deviceId] = .now
            probe(machine, relay: relayTransport(machine))
        }
    }

    private func probe(_ machine: CloudMachine, relay: any CloudChannelTransport) {
        let deviceId = machine.deviceId
        let onDown: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleDown(deviceId: deviceId) }
        }
        probeTasks[deviceId] = Task { [weak self, prober] in
            let connection = await prober(machine, relay, onDown)
            guard let self, !Task.isCancelled else {
                await connection?.shutdown()
                return
            }
            self.probeTasks[deviceId] = nil
            guard let connection else { return }
            guard self.connections[deviceId] == nil else {
                // A concurrent path won the race; keep the established pipe.
                await connection.shutdown()
                return
            }
            self.connections[deviceId] = (connection, machine.publicKey)
            self.machineIds.insert(deviceId)
            Log.cloud.log("Direct path to machine \(deviceId, privacy: .public) is up")
        }
    }

    private func handleDown(deviceId: String) {
        guard connections.removeValue(forKey: deviceId) != nil else { return }
        machineIds.remove(deviceId)
        // Allow an immediate re-probe on the next refresh: the pipe dying is
        // fresh information, unlike a failed probe against a silent address.
        lastAttempt[deviceId] = nil
        Log.cloud.log("Direct path to machine \(deviceId, privacy: .public) went down")
    }

    /// The direct transport for a machine, iff its live pipe seals toward
    /// exactly the given (verified) key. nil = use the relay.
    public func transport(for deviceId: String, publicKey: String) -> (any CloudChannelTransport)? {
        guard let entry = connections[deviceId], entry.publicKey == publicKey else { return nil }
        return CloudDirectTransport(connection: entry.connection)
    }

    /// Silently tears down one machine's pipe (removal, key change).
    public func drop(deviceId: String) {
        probeTasks.removeValue(forKey: deviceId)?.cancel()
        machineIds.remove(deviceId)
        guard let entry = connections.removeValue(forKey: deviceId) else { return }
        Task { await entry.connection.shutdown() }
    }

    /// Sign-out / server switch: everything goes.
    public func dropAll() {
        for deviceId in Set(connections.keys).union(probeTasks.keys) {
            drop(deviceId: deviceId)
        }
        lastAttempt = [:]
    }
}

// MARK: - Default prober

extension CloudDirectPathController {
    static func defaultProber(
        credentialStore: any CloudCredentialStore,
        webSocketTransport: any ServerWebSocketTransport
    ) -> Prober {
        { machine, relay, onDown in
            guard let discovery = await Self.discoverDirectPath(over: relay),
                discovery.deviceId == machine.deviceId
            else { return nil }
            for host in discovery.hosts {
                guard let url = URL(string: "ws://\(host):\(discovery.port)/v1/direct") else {
                    continue
                }
                let connection = CloudDirectConnection(
                    directURL: url,
                    machineDeviceId: machine.deviceId,
                    machinePublicKey: machine.publicKey,
                    credentialStore: credentialStore,
                    webSocketTransport: webSocketTransport,
                    onDown: onDown
                )
                if await Self.verifySealedRoundTrip(connection) { return connection }
                await connection.shutdown()
            }
            return nil
        }
    }

    /// Asks the machine, over the relay, where its direct listener lives.
    /// The relay path arrives on the machine via loopback, so the route is
    /// authorized like any other data route.
    static func discoverDirectPath(over relay: any CloudChannelTransport) async -> Discovery? {
        let http = CloudRelayRequestTransport(endpoint: relay, timeout: .seconds(10))
        // Only path/method travel over the channel; the host is a placeholder.
        guard let url = URL(string: "http://machine.invalid/v1/net/direct"),
            let (data, response) = try? await http.data(for: URLRequest(url: url)),
            response.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Discovery.self, from: data)
    }

    /// One sealed request over the candidate pipe. Success requires the far
    /// end to complete the channel key agreement with the pinned machine key,
    /// so an imposter listener (or a stale machine behind a reused LAN
    /// address) fails here and the candidate is discarded.
    static func verifySealedRoundTrip(_ connection: CloudDirectConnection) async -> Bool {
        let http = CloudRelayRequestTransport(
            endpoint: CloudDirectTransport(connection: connection),
            timeout: .seconds(6)
        )
        guard let url = URL(string: "http://machine.invalid/v1/info") else { return false }
        return (try? await http.data(for: URLRequest(url: url))) != nil
    }
}
