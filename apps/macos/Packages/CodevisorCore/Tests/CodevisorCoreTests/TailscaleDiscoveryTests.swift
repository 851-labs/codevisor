import Foundation
import Testing
@testable import CodevisorCore

@Suite("Tailscale discovery")
struct TailscaleDiscoveryTests {
    private let statusFixture = """
    {
      "Version": "1.98.8",
      "BackendState": "Running",
      "Self": {
        "HostName": "my-mac",
        "DNSName": "my-mac.tail6fc9a.ts.net.",
        "TailscaleIPs": ["100.64.0.1"],
        "OS": "macOS",
        "Online": true
      },
      "Peer": {
        "key1": {
          "HostName": "build-box",
          "DNSName": "build-box.tail6fc9a.ts.net.",
          "TailscaleIPs": ["100.64.0.2", "fd7a::2"],
          "OS": "linux",
          "Online": true
        },
        "key2": {
          "HostName": "asleep-laptop",
          "DNSName": "asleep-laptop.tail6fc9a.ts.net.",
          "TailscaleIPs": ["100.64.0.3"],
          "OS": "macOS",
          "Online": false
        },
        "key3": {
          "HostName": "bare-peer",
          "DNSName": "",
          "TailscaleIPs": ["100.64.0.4"],
          "Online": true
        }
      }
    }
    """.data(using: .utf8)!

    @Test("Decodes peers from status --json, stripping trailing DNS dots")
    func decodesPeers() {
        let peers = TailscaleStatusReader.peers(fromStatusJSON: statusFixture)
        #expect(peers?.count == 3)
        let buildBox = peers?.first { $0.hostName == "build-box" }
        #expect(buildBox?.dnsName == "build-box.tail6fc9a.ts.net")
        #expect(buildBox?.ip == "100.64.0.2")
        #expect(buildBox?.os == "linux")
        #expect(buildBox?.online == true)
        #expect(buildBox?.host == "build-box.tail6fc9a.ts.net")
        // Empty DNS names fall back to the IP for dialing.
        let bare = peers?.first { $0.hostName == "bare-peer" }
        #expect(bare?.dnsName == nil)
        #expect(bare?.host == "100.64.0.4")
    }

    @Test("Rejects garbage and reports empty when the backend is stopped")
    func handlesEdgeCases() {
        #expect(TailscaleStatusReader.peers(fromStatusJSON: Data("nonsense".utf8)) == nil)
        let stopped = Data(#"{"BackendState": "Stopped", "Peer": {}}"#.utf8)
        #expect(TailscaleStatusReader.peers(fromStatusJSON: stopped) == [])
        #expect(TailscaleStatusReader.peers(fromStatusJSON: Data("{}".utf8)) == [])
    }

    @Test("Reports unavailable when no tailscale binary exists")
    func readerUnavailable() async {
        let peers = await TailscaleStatusReader.readPeers(candidates: ["/nonexistent-tailscale"])
        #expect(peers == nil)
    }

    @Test("Probes online unregistered peers and sorts results")
    @MainActor
    func discoversUnregisteredServers() async {
        let peers = TailscaleStatusReader.peers(fromStatusJSON: statusFixture)!
        let service = MachineDiscoveryService(
            peerSource: { peers },
            probe: { host in
                switch host {
                case "build-box.tail6fc9a.ts.net":
                    ServerDiscoveryInfo(
                        serverId: "local",
                        machineId: "machine-1",
                        name: "local",
                        kind: "remote",
                        version: "1.2.3",
                        platform: "linux",
                        hostname: "build-box"
                    )
                default:
                    nil
                }
            }
        )

        await service.refresh(registeredHosts: [])
        #expect(service.isAvailable)
        #expect(service.discovered == [
            DiscoveredMachine(
                id: "machine-1",
                name: "build-box",
                host: "build-box.tail6fc9a.ts.net",
                version: "1.2.3",
                os: "linux"
            )
        ])

        // Already-registered hosts disappear from the section.
        await service.refresh(registeredHosts: ["build-box.tail6fc9a.ts.net"])
        #expect(service.discovered.isEmpty)
    }

    @Test("Discovery turns off when tailscale is absent")
    @MainActor
    func unavailableWithoutTailscale() async {
        let service = MachineDiscoveryService(peerSource: { nil }, probe: { _ in nil })
        await service.refresh(registeredHosts: [])
        #expect(service.isAvailable == false)
        #expect(service.discovered.isEmpty)
    }

    @Test("Falls back to the hostname when a server advertises the generic name")
    func displayNames() {
        let peer = TailscalePeer(hostName: "peer-host", online: true)
        let generic = ServerDiscoveryInfo(
            serverId: "local", machineId: "m", name: "local", kind: "remote",
            version: "1", platform: "linux", hostname: "vmi3431000"
        )
        #expect(MachineDiscoveryService.displayName(info: generic, peer: peer) == "vmi3431000")
        let named = ServerDiscoveryInfo(
            serverId: "local", machineId: "m", name: "Build Box", kind: "remote",
            version: "1", platform: "linux", hostname: "vmi3431000"
        )
        #expect(MachineDiscoveryService.displayName(info: named, peer: peer) == "Build Box")
        let empty = ServerDiscoveryInfo(
            serverId: "local", machineId: "m", name: "Local Codevisor", kind: "remote",
            version: "1", platform: "linux", hostname: ""
        )
        #expect(MachineDiscoveryService.displayName(info: empty, peer: peer) == "peer-host")
    }
}
