import CodevisorCore
import Darwin
import Foundation

/// iOS-side machine discovery. The Mac app enumerates tailnet peers with the
/// Tailscale CLI; iOS has no CLI and Tailscale offers third-party apps no
/// peer list, so discovery here is two honest halves:
///
/// 1. Detect that Tailscale is up — the quad-100 endpoint
///    (`http://100.100.100.100/api/data`) tokenlessly reports the tailnet
///    name, with an interface scan (a 100.64.0.0/10 address) as fallback.
/// 2. Find a specific machine by probing its tokenless `/v1/discovery`
///    manifest, exactly like the macOS prober — MagicDNS resolves the short
///    machine name once Tailscale is connected.
enum TailnetDiscovery {
    /// What we can learn about the phone's Tailscale connection.
    struct TailnetInfo: Equatable, Sendable {
        /// MagicDNS tailnet domain, e.g. `tail6fc9a.ts.net`; empty when only
        /// the VPN interface gave Tailscale away.
        var tailnetName: String
        var deviceName: String
    }

    /// The tokenless `/v1/discovery` manifest a Codevisor server serves so
    /// peers can be recognized before pairing (mirror of the macOS decoder,
    /// which lives in the Mac-only package).
    struct Manifest: Decodable, Equatable, Sendable {
        var serverId: String
        var machineId: String
        var name: String
        var kind: String
        var version: String
        var platform: String
        var hostname: String
    }

    /// A found server plus the address that reached it (the address is what
    /// gets registered, so it must be the one that worked).
    struct FoundMachine: Equatable, Sendable {
        var host: String
        var manifest: Manifest
    }

    // MARK: - Tailscale detection

    /// Nil when Tailscale isn't running on this device.
    static func detectTailscale() async -> TailnetInfo? {
        if let info = await readQuad100() { return info }
        guard hasTailnetInterface() else { return nil }
        return TailnetInfo(tailnetName: "", deviceName: "")
    }

    /// Tailscale's own resolver address serves a small tokenless status
    /// document while connected — the closest thing iOS has to
    /// `tailscale status`.
    private static func readQuad100() async -> TailnetInfo? {
        struct Quad100Data: Decodable {
            var Status: String?
            var TailnetName: String?
            var DeviceName: String?
        }
        guard let url = URL(string: "http://100.100.100.100/api/data") else { return nil }
        guard let data = await fetch(url, timeout: 1.5),
            let decoded = try? JSONDecoder().decode(Quad100Data.self, from: data),
            decoded.Status == "Running"
        else { return nil }
        return TailnetInfo(
            tailnetName: decoded.TailnetName ?? "",
            deviceName: decoded.DeviceName ?? ""
        )
    }

    /// True when any interface carries a CGNAT 100.64.0.0/10 address — the
    /// range Tailscale assigns; the fallback when quad-100 doesn't answer.
    private static func hasTailnetInterface() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return false }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var ipv4 = sockaddr_in()
            memcpy(&ipv4, address, MemoryLayout<sockaddr_in>.size)
            let value = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            if value & 0xFFC0_0000 == 0x6440_0000 { return true }
        }
        return false
    }

    // MARK: - Machine probing

    /// Probes a user-supplied machine name or address for a Codevisor
    /// server. Bare names stay unqualified (MagicDNS and ATS both prefer
    /// them); an explicit port wins over the production port.
    static func probe(_ input: String) async -> FoundMachine? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { return nil }
        let hasPort = host.split(separator: ":").count == 2 && !host.contains("::")
        let authority = hasPort ? host : "\(host):\(CodevisorServerConfig.productionPort)"
        guard let url = URL(string: "http://\(authority)/v1/discovery") else { return nil }
        guard let data = await fetch(url, timeout: 2),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return FoundMachine(host: host, manifest: manifest)
    }

    private static func fetch(_ url: URL, timeout: TimeInterval) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}

/// Automatic tailnet discovery, the iOS analog of the macOS "On Your
/// Network" section. iOS can't enumerate tailnet peers itself, but a paired
/// machine's server can (`GET /v1/tailnet/peers` runs the Tailscale CLI
/// there) — so this asks a paired machine for the peer list, then probes
/// each online peer's tokenless `/v1/discovery` from the phone, which also
/// proves the address works from this device before it gets registered.
@MainActor
@Observable
final class TailnetMachineDiscovery {
    struct Discovered: Identifiable, Equatable, Sendable {
        /// The server's stable machine identity.
        var id: String
        var name: String
        var host: String
        var version: String
    }

    private(set) var discovered: [Discovered] = []
    private(set) var isRefreshing = false

    /// One discovery pass. Quiet on every failure path — no paired machine
    /// reachable, no Tailscale anywhere, nothing found — the section simply
    /// stays hidden.
    func refresh(machines: MachineController) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // The phone must be on the tailnet itself, or probing peers (and
        // dialing any machine we'd find) could never succeed.
        guard await TailnetDiscovery.detectTailscale() != nil else {
            discovered = []
            return
        }

        let remotes = machines.machines.filter { !$0.isLocal }
        let registeredHosts = Set(remotes.compactMap { $0.baseURL.host()?.lowercased() })

        // First paired machine whose server knows its tailnet wins; their
        // views are the same tailnet, so one answer is enough.
        var peers: [ServerTailnetPeer] = []
        for machine in remotes {
            guard let response = try? await machines.client(for: machine.id).tailnetPeers(),
                response.available
            else { continue }
            peers = response.peers
            break
        }

        let candidates = peers.filter { peer in
            guard peer.online, let host = peer.host else { return false }
            if registeredHosts.contains(host.lowercased()) { return false }
            if let ip = peer.ip, registeredHosts.contains(ip.lowercased()) { return false }
            if let dnsName = peer.dnsName, registeredHosts.contains(dnsName.lowercased()) { return false }
            return true
        }

        // Bounded fan-out, mirroring the macOS discovery service: enough
        // parallelism to finish a big tailnet in a couple of timeouts.
        var found: [Discovered] = []
        for chunk in candidates.chunked(into: 8) {
            let results = await withTaskGroup(of: Discovered?.self) { group in
                for peer in chunk {
                    group.addTask {
                        guard let host = peer.host,
                            let machine = await TailnetDiscovery.probe(host)
                        else { return nil }
                        return Discovered(
                            id: machine.manifest.machineId,
                            name: Self.displayName(manifest: machine.manifest, peer: peer),
                            host: host,
                            version: machine.manifest.version
                        )
                    }
                }
                var collected: [Discovered] = []
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
    private nonisolated static func displayName(
        manifest: TailnetDiscovery.Manifest,
        peer: ServerTailnetPeer
    ) -> String {
        if manifest.name != "local" && manifest.name != "Local Codevisor" {
            return manifest.name
        }
        return manifest.hostname.isEmpty ? peer.hostName : manifest.hostname
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
