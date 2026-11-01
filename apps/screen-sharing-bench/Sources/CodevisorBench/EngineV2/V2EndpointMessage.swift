import CodevisorNet

struct V2EndpointMessage: Codable, Sendable {
  let endpointId: String
  let directAddrs: [String]

  init(_ addr: NetTunnelAddr) {
    endpointId = addr.endpointId
    directAddrs = addr.directAddrs
  }

  func addr(reachingHost host: String) -> NetTunnelAddr {
    let ports = Set(directAddrs.compactMap { $0.split(separator: ":").last.map(String.init) })
    let viaSignaling = ports.sorted().map { "\(host):\($0)" }
    return NetTunnelAddr(endpointId: endpointId, relayUrl: nil, directAddrs: viaSignaling + directAddrs)
  }
}
