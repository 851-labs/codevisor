import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Machine connection presentation")
struct MachineConnectionPresentationTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static let peerToPeer = CloudMachineReach(online: true, hasTunnel: true, route: .peerToPeer(milliseconds: 12))

  private func presentation(
    reachable: Bool? = true,
    availability: ServerAvailability? = .ready,
    sync: NavigationSyncState? = .current,
    cloud: CloudMachineReach? = peerToPeer,
    address: String? = nil,
    roundTrip: Int? = nil,
    isLocal: Bool = false
  ) -> MachineConnectionPresentation {
    MachineConnectionPresentation(
      isLocal: isLocal,
      status: reachable.map { MachineStatus(isReachable: $0, label: "Probe failed", roundTripMilliseconds: roundTrip) },
      availability: availability,
      navigationSyncState: sync,
      cloud: cloud,
      address: address
    )
  }

  @Test("A connected cloud machine says how it's reached and its round trip")
  func tunnelRoutes() {
    let direct = presentation()
    #expect(direct.label() == "Peer-to-peer · 12 ms")
    #expect(direct.indicator == .connected)
    #expect(direct.help == "Direct encrypted connection")

    let relayed = presentation(
      cloud: CloudMachineReach(
        online: true, hasTunnel: true,
        route: .relayed(relayURL: "https://relay-sjc-1.codevisor.dev/", milliseconds: 48)))
    #expect(relayed.label() == "Relayed · 48 ms")
    #expect(relayed.help == "Through the Codevisor relay in San Jose; a direct connection wasn't possible")
  }

  @Test("This Mac, and machines added by address with the status check's round trip")
  func otherKinds() {
    #expect(presentation(cloud: nil, isLocal: true).label() == "This Mac")
    let byAddress = presentation(cloud: nil, address: "100.113.201.5:49361", roundTrip: 8)
    #expect(byAddress.label() == "Public IP · 8 ms")
    #expect(byAddress.help == "Connected to 100.113.201.5:49361")
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
