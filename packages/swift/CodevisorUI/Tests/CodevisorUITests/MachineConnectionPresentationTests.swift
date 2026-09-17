import CodevisorCore
import Testing
@testable import CodevisorUI

@Suite("Machine connection presentation")
struct MachineConnectionPresentationTests {
  private func presentation(
    reachable: Bool? = true,
    availability: ServerAvailability? = .ready,
    sync: NavigationSyncState? = .current,
    cloudOnline: Bool? = true,
    direct: Bool = true
  ) -> MachineConnectionPresentation {
    MachineConnectionPresentation(
      status: reachable.map { MachineStatus(isReachable: $0, label: "Probe failed") },
      availability: availability,
      navigationSyncState: sync,
      cloudOnline: cloudOnline,
      usesDirectConnection: direct
    )
  }

  @Test("Cloud presence and a direct path cannot hide a failed client probe")
  func failedProbeOverridesPresence() {
    let result = presentation(reachable: false)
    #expect(result == .offline)
    #expect(result.label == "Offline")
  }

  @Test("A failed request gate cannot be hidden by an earlier successful probe")
  func failedAvailabilityOverridesProbe() {
    let result = presentation(availability: .failed("Invalid connection token"))
    #expect(result == .offline)
  }

  @Test("A reachable machine with stale navigation shows Offline")
  func syncFailureOverridesPresence() {
    let result = presentation(sync: .stale("Timed out syncing with this machine."))
    #expect(result == .offline)
    #expect(result.label == "Offline")
  }

  @Test("Automatic retries retain Offline until recovery succeeds")
  func recovery() {
    #expect(presentation(availability: .failed("Unreachable")) == .offline)
    let retrying = presentation(
      reachable: false, availability: .waiting(.connecting), sync: .stale("Unreachable"))
    #expect(retrying == .offline)
    #expect(presentation(availability: .waiting(.connecting), sync: .stale("Sync failed")) == .offline)
    #expect(presentation(sync: .catchingUp) == .syncing)
    let recovered = presentation()
    #expect(recovered == .online(isDirect: true))
  }

  @Test("Unprobed machines never claim to be online from cloud presence alone")
  func unknownReachability() {
    #expect(presentation(reachable: nil, availability: nil, sync: nil) == .checking)
    #expect(presentation(reachable: nil, availability: nil, sync: nil, cloudOnline: nil) == .checking)
    #expect(presentation(reachable: nil, availability: nil, sync: nil, cloudOnline: false) == .offline)
  }

  @Test("Reachable machines wait for a current navigation snapshot")
  func initialSync() {
    for sync in [nil, NavigationSyncState.cached, .catchingUp] {
      #expect(presentation(sync: sync) == .syncing)
    }
  }

  @Test("Healthy direct and relayed connections retain their status")
  func healthyConnections() {
    #expect(presentation(cloudOnline: false).label == "Online · Direct")
    #expect(presentation(direct: false).label == "Online")
  }

  @Test("Known lifecycle transitions supersede an earlier healthy status")
  func lifecycleTransitions() {
    for reason in [ServerWaitingReason.starting, .connecting, .updating, .restarting] {
      let result = presentation(availability: .waiting(reason))
      #expect(result == .waiting(reason))
    }
  }
}
