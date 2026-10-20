import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Machine connection presentation")
struct MachineConnectionPresentationTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static let lan = reach(.localNetwork(address: "192.168.1.20"), milliseconds: 12)

  private func presentation(
    reachable: Bool? = true,
    availability: ServerAvailability? = .ready,
    sync: NavigationSyncState? = .current,
    cloud: CloudMachineReach? = lan,
    isLocal: Bool = false
  ) -> MachineConnectionPresentation {
    MachineConnectionPresentation(
      isLocal: isLocal,
      status: reachable.map { MachineStatus(isReachable: $0, label: "Probe failed") },
      availability: availability,
      navigationSyncState: sync,
      cloud: cloud
    )
  }

  private static func reach(_ route: CloudTunnelRoute, milliseconds: Int) -> CloudMachineReach {
    CloudMachineReach(
      online: true, hasTunnel: true, path: CloudTunnelPath(route: route, roundTripMilliseconds: milliseconds))
  }

  @Test("A connected cloud machine names its path and round trip, with where it goes on hover")
  func tunnelRoutes() {
    let lan = presentation()
    #expect(lan.label() == "Local network · 12 ms")
    #expect(lan.indicator == .connected)
    #expect(lan.help == "192.168.1.20")

    let tailscale = presentation(cloud: Self.reach(.tailscale(address: "100.101.102.103"), milliseconds: 30))
    #expect(tailscale.label() == "Tailscale · 30 ms")
    #expect(tailscale.help == "100.101.102.103")

    let internet = presentation(cloud: Self.reach(.internet(address: "203.0.113.9"), milliseconds: 70))
    #expect(internet.label() == "Internet · 70 ms")

    let relayed = presentation(cloud: Self.reach(.relay(url: "https://relay-sjc-1.codevisor.dev/"), milliseconds: 48))
    #expect(relayed.label() == "Codevisor relay · 48 ms")
    #expect(relayed.help == "San Jose")
  }

  @Test("A reachable machine whose path isn't read yet just says it's connected")
  func connectedWithoutPath() {
    let result = presentation(cloud: CloudMachineReach(online: true, hasTunnel: true))
    #expect(result.label() == "Connected")
    #expect(result.help == nil)
  }

  @Test("This Mac is labeled as such")
  func thisMac() {
    #expect(presentation(cloud: nil, isLocal: true).label() == "This Mac")
  }

  @Test("A machine this device can't reach is offline, whatever the hub says, with when it was last seen")
  func offline() {
    let reach = CloudMachineReach(online: true, hasTunnel: true, lastSeen: Self.now.addingTimeInterval(-7200))
    let result = presentation(reachable: false, cloud: reach)
    #expect(result.indicator == .inactive)
    #expect(result.label(now: Self.now) == "Last seen 2 hours ago")
    #expect(presentation(reachable: false, cloud: nil).label() == "Offline")
    let unprobed = presentation(
      reachable: nil, availability: nil, sync: nil, cloud: CloudMachineReach(online: false, hasTunnel: true))
    #expect(unprobed == .offline(lastSeen: nil))
  }

  @Test("A machine whose Codevisor predates the tunnel needs an update")
  func updateNeeded() {
    let result = presentation(reachable: nil, cloud: CloudMachineReach(online: true, hasTunnel: false))
    #expect(result == .updateNeeded)
    #expect(result.label() == "Update needed")
    #expect(result.indicator == .inactive)
  }

  @Test("Dialing and lifecycle transitions show a spinner and say what's happening")
  func busy() {
    let dialing = presentation(
      reachable: nil, availability: nil, sync: nil,
      cloud: CloudMachineReach(online: true, hasTunnel: true, dialing: true))
    #expect(dialing == .connecting)
    #expect(dialing.label() == "Connecting…")
    #expect(dialing.indicator == .busy)
    for (reason, label) in [
      (ServerWaitingReason.starting, "Starting…"), (.updating, "Updating…"), (.restarting, "Restarting…"),
    ] {
      #expect(presentation(availability: .waiting(reason)).label() == label)
    }
    #expect(presentation(sync: .catchingUp) == .syncing)
  }

  @Test("Failures override an earlier healthy status, and retries keep showing offline")
  func failures() {
    #expect(presentation(availability: .failed("Invalid connection token")) == .offline(lastSeen: nil))
    #expect(presentation(sync: .stale("Timed out syncing with this machine.")) == .offline(lastSeen: nil))
    let retrying = presentation(reachable: false, availability: .waiting(.connecting), sync: .stale("Unreachable"))
    #expect(retrying == .offline(lastSeen: nil))
    #expect(presentation(availability: .waiting(.connecting)) == .connecting)
  }

  @Test("Recently seen reads as just now")
  func justNow() {
    let result = MachineConnectionPresentation.offline(lastSeen: Self.now.addingTimeInterval(-20))
    #expect(result.label(now: Self.now) == "Last seen just now")
  }
}
