import Testing
@testable import CodevisorCloud

@Suite("Local network probe target")
struct LocalNetworkProbeTargetTests {
  @Test(
    "A neighbor of this device's address that is not the network's first or last host",
    arguments: [
      ("192.168.10.200", 24, "192.168.10.201"),
      ("192.168.10.253", 24, "192.168.10.252"),
      ("10.0.0.2", 8, "10.0.0.3"),
      ("192.168.1.6", 29, "192.168.1.5"),
    ]
  )
  func neighbor(address: String, prefixLength: Int, expected: String) {
    #expect(LocalNetworkProbeTarget.address(in: [network("en0", address, prefixLength)]) == expected)
  }

  @Test("Link-local and tiny subnets are skipped, and en interfaces come first")
  func skipsUnusableNetworks() {
    let networks = [
      network("bridge100", "192.168.64.1", 24),
      network("en1", "169.254.3.4", 16),
      network("en1", "192.168.1.234", 24),
    ]
    #expect(LocalNetworkProbeTarget.address(in: networks) == "192.168.1.235")
    #expect(LocalNetworkProbeTarget.address(in: [network("en0", "192.168.1.1", 30)]) == nil)
  }

  private func network(_ name: String, _ address: String, _ prefixLength: Int) -> LocalIPv4Network {
    let value = address.split(separator: ".").reduce(UInt32(0)) { $0 << 8 | UInt32($1)! }
    return LocalIPv4Network(interfaceName: name, address: value, prefixLength: prefixLength)
  }
}
