import Testing
@testable import CodevisorCloud

@Suite("Cloud tunnel route")
struct CloudTunnelRouteTests {
  static let homeSubnet = [CloudAddressRange("2600:1700:abcd:1::/64")].compactMap { $0 }

  @Test(
    "A direct path is named for the network it crosses",
    arguments: [
      ("192.168.10.20:51820", CloudTunnelRoute.localNetwork(address: "192.168.10.20")),
      ("172.20.1.5:4000", .localNetwork(address: "172.20.1.5")),
      ("[fe80::1c89:5f8d%14]:7842", .localNetwork(address: "fe80::1c89:5f8d")),
      ("[::ffff:10.0.0.7]:7842", .localNetwork(address: "10.0.0.7")),
      ("[2600:1700:abcd:1::42]:7842", .localNetwork(address: "2600:1700:abcd:1::42")),
      ("100.101.102.103:41641", .tailscale(address: "100.101.102.103")),
      ("[fd7a:115c:a1e0::6535:5c24]:41641", .tailscale(address: "fd7a:115c:a1e0::6535:5c24")),
      ("100.128.0.1:41641", .internet(address: "100.128.0.1")),
      ("203.0.113.9:7842", .internet(address: "203.0.113.9")),
      ("[2600:1700:abcd:2::42]:7842", .internet(address: "2600:1700:abcd:2::42")),
    ]
  )
  func direct(remote: String, expected: CloudTunnelRoute) {
    #expect(CloudTunnelRoute(remote: remote, isRelay: false, localSubnets: Self.homeSubnet) == expected)
  }

  @Test("A relayed path keeps the relay it goes through")
  func relayed() {
    let route = CloudTunnelRoute(remote: "https://relay-sjc-1.codevisor.dev/", isRelay: true, localSubnets: [])
    #expect(route == .relay(url: "https://relay-sjc-1.codevisor.dev/"))
  }
}
