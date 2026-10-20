import CodevisorCore
import Foundation

struct MachineRouteDescription {
  let path: CloudTunnelPath?

  var label: String {
    guard let path else { return "Connected" }
    return "\(Self.name(path.route)) · \(path.roundTripMilliseconds) ms"
  }

  var help: String? {
    path.map { Self.place($0.route) }
  }

  private static func name(_ route: CloudTunnelRoute) -> String {
    switch route {
    case .localNetwork: "Local network"
    case .tailscale: "Tailscale"
    case .internet: "Internet"
    case .relay: "Codevisor relay"
    }
  }

  private static func place(_ route: CloudTunnelRoute) -> String {
    switch route {
    case .localNetwork(let address), .tailscale(let address), .internet(let address): address
    case .relay(let url): relayPlace(url) ?? URL(string: url)?.host() ?? url
    }
  }

  private static func relayPlace(_ url: String) -> String? {
    guard let host = URL(string: url)?.host() else { return nil }
    let places = ["iad": "Virginia", "sjc": "San Jose", "fra": "Frankfurt", "sin": "Singapore"]
    let region = host.split(separator: ".").first?.split(separator: "-").dropFirst().first.map(String.init)
    return region.flatMap { places[$0] }
  }
}
