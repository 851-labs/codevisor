import Foundation

/// A machine on the user's tailnet, decoded from `tailscale status --json`.
public struct TailscalePeer: Equatable, Sendable {
    public var hostName: String
    /// MagicDNS name with the trailing dot stripped; preferred over the IP
    /// because it survives IP reassignment.
    public var dnsName: String?
    public var ip: String?
    public var os: String?
    public var online: Bool

    public init(hostName: String, dnsName: String? = nil, ip: String? = nil, os: String? = nil, online: Bool) {
        self.hostName = hostName
        self.dnsName = dnsName
        self.ip = ip
        self.os = os
        self.online = online
    }

    /// The address a client should dial: MagicDNS name, else the tailnet IP.
    public var host: String? {
        dnsName ?? ip
    }
}

/// Reads the local Tailscale daemon's view of the tailnet by shelling out to
/// the CLI. The CLI is the one interface every install variant (App Store,
/// standalone GUI, open-source tailscaled) exposes consistently; absence of
/// all candidates simply means "no Tailscale here" and discovery stays off.
public enum TailscaleStatusReader {
    public static let binaryCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale"
    ]

    /// Decodes the JSON printed by `tailscale status --json`. Exposed for
    /// fixture tests; field names follow Tailscale's own casing.
    public static func peers(fromStatusJSON data: Data) -> [TailscalePeer]? {
        struct Node: Decodable {
            var HostName: String?
            var DNSName: String?
            var TailscaleIPs: [String]?
            var OS: String?
            var Online: Bool?
        }
        struct Status: Decodable {
            var BackendState: String?
            var Peer: [String: Node]?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        guard status.BackendState == nil || status.BackendState == "Running" else { return [] }
        return (status.Peer ?? [:]).values.compactMap { node in
            guard let hostName = node.HostName, !hostName.isEmpty else { return nil }
            let dnsName = node.DNSName.flatMap { name -> String? in
                let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
                return trimmed.isEmpty ? nil : trimmed
            }
            return TailscalePeer(
                hostName: hostName,
                dnsName: dnsName,
                ip: node.TailscaleIPs?.first,
                os: node.OS,
                online: node.Online ?? false
            )
        }
        .sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
    }

    /// Runs the first installed Tailscale binary. Nil when Tailscale is not
    /// installed or the command fails — callers hide discovery entirely.
    public static func readPeers(
        candidates: [String] = binaryCandidates,
        fileManager: FileManager = .default
    ) async -> [TailscalePeer]? {
        guard let binary = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
        else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["status", "--json"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: finished.terminationStatus == 0 ? output : nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
        guard let data else { return nil }
        return peers(fromStatusJSON: data)
    }
}

/// The tokenless manifest a Codevisor server exposes at `/v1/discovery` so
/// tailnet peers can be recognized before pairing.
public struct ServerDiscoveryInfo: Decodable, Equatable, Sendable {
    public var serverId: String
    public var machineId: String
    public var name: String
    public var kind: String
    public var version: String
    public var platform: String
    public var hostname: String

    public init(
        serverId: String,
        machineId: String,
        name: String,
        kind: String,
        version: String,
        platform: String,
        hostname: String
    ) {
        self.serverId = serverId
        self.machineId = machineId
        self.name = name
        self.kind = kind
        self.version = version
        self.platform = platform
        self.hostname = hostname
    }
}

/// A Codevisor server found on the tailnet that isn't in the machine list
/// yet. Adding it still requires the machine's connection token.
public struct DiscoveredMachine: Identifiable, Equatable, Sendable {
    /// The server's stable machine identity.
    public var id: String
    public var name: String
    public var host: String
    public var version: String
    public var os: String?

    public init(id: String, name: String, host: String, version: String, os: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.version = version
        self.os = os
    }
}

/// Finds Codevisor servers among tailnet peers by probing the tokenless
/// `/v1/discovery` manifest on each online peer. Refreshes only while a
/// presenting view is on screen — no background polling.
@MainActor
@Observable
public final class MachineDiscoveryService {
    public typealias PeerSource = @Sendable () async -> [TailscalePeer]?
    public typealias Prober = @Sendable (String) async -> ServerDiscoveryInfo?

    /// False when Tailscale isn't installed; the UI hides discovery entirely.
    public private(set) var isAvailable = true
    public private(set) var discovered: [DiscoveredMachine] = []
    public private(set) var isRefreshing = false

    private let peerSource: PeerSource
    private let probe: Prober

    public init(
        peerSource: @escaping PeerSource = { await TailscaleStatusReader.readPeers() },
        probe: @escaping Prober = MachineDiscoveryService.probeDiscovery
    ) {
        self.peerSource = peerSource
        self.probe = probe
    }

    /// One discovery pass. `registeredHosts` are addresses already in the
    /// machine list (by DNS name or IP) — those peers are skipped so the
    /// section only ever shows machines the user could add.
    public func refresh(registeredHosts: Set<String>) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let peers = await peerSource() else {
            isAvailable = false
            discovered = []
            return
        }
        isAvailable = true
        let candidates = peers.filter { peer in
            guard peer.online, let host = peer.host else { return false }
            if registeredHosts.contains(host) { return false }
            if let ip = peer.ip, registeredHosts.contains(ip) { return false }
            if let dnsName = peer.dnsName, registeredHosts.contains(dnsName) { return false }
            return true
        }

        let probe = self.probe
        var found: [DiscoveredMachine] = []
        // Bounded fan-out: enough parallelism to finish a big tailnet in a
        // couple of timeouts, without opening a connection per peer at once.
        for chunk in candidates.chunked(into: 8) {
            let results = await withTaskGroup(of: DiscoveredMachine?.self) { group in
                for peer in chunk {
                    group.addTask {
                        guard let host = peer.host, let info = await probe(host) else { return nil }
                        let name = Self.displayName(info: info, peer: peer)
                        return DiscoveredMachine(
                            id: info.machineId,
                            name: name,
                            host: host,
                            version: info.version,
                            os: peer.os
                        )
                    }
                }
                var collected: [DiscoveredMachine] = []
                for await result in group {
                    if let result {
                        collected.append(result)
                    }
                }
                return collected
            }
            found.append(contentsOf: results)
        }
        discovered = found.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Servers that predate the hostname default advertise the generic
    /// "local" id; the machine's hostname reads much better in a picker.
    nonisolated static func displayName(info: ServerDiscoveryInfo, peer: TailscalePeer) -> String {
        if info.name != "local" && info.name != "Local Codevisor" {
            return info.name
        }
        return info.hostname.isEmpty ? peer.hostName : info.hostname
    }

    /// Tokenless probe of a candidate peer. Short timeout: on-tailnet servers
    /// answer in milliseconds, and everything else should fail fast.
    nonisolated public static let probeDiscovery: Prober = { host in
        guard let url = URL(string: "http://\(host):\(CodevisorServerConfig.productionPort)/v1/discovery")
        else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(ServerDiscoveryInfo.self, from: data)
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
