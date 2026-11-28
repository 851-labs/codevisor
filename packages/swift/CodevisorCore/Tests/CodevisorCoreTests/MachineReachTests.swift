import CodevisorCloud
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Machine reach")
struct MachineReachTests {
  private let studio = accountMachine("studio", name: "Mac Studio")

  private func offlinePresence(of machine: CodevisorMachine) -> CloudMachine {
    makeCloudMachine(deviceId: "studio", name: machine.name, online: false)
  }

  @Test("A machine that has gone offline is quiet, not failed, and comes back ready")
  func offlineMachineIsQuiet() {
    let (machines, _, _) = makeController(localServer: nil)
    let provider = signIn(machines, machines: [studio])
    provider.cloudMachines = [offlinePresence(of: studio)]

    machines.markFailed(for: studio.id, message: "Mac Studio is offline")
    #expect(machines.reach(for: studio.id) == .quiet)

    machines.markReady(for: studio.id)
    #expect(machines.reach(for: studio.id) == .ready)
  }

  @Test("This Mac's own server failing is a real failure")
  func localFailureIsFailed() {
    let (machines, _, _) = makeController()

    machines.markFailed(for: CodevisorMachine.local.id, message: "The server didn't start")

    #expect(machines.reach(for: CodevisorMachine.local.id) == .failed("The server didn't start"))
  }

  @Test("A machine the cloud sees online but can't tunnel to needs an update")
  func onlineWithoutTunnelNeedsUpdate() {
    let (machines, _, _) = makeController(localServer: nil)
    signIn(machines, machines: [studio])

    machines.markFailed(for: studio.id, message: "Unreachable")

    #expect(machines.reach(for: studio.id) == .needsAction(.updateNeeded))
  }

  @Test("A machine that is no longer in the account was removed")
  func missingMachineWasRemoved() {
    let (machines, _, _) = makeController(localServer: nil)
    signIn(machines, machines: [])

    #expect(machines.reach(for: studio.id) == .needsAction(.removed))
  }

  @Test("This device shows as offline only once it has been unable to reach the cloud for a while")
  func deviceOfflineWaitsOutBlips() async {
    let clock = ManualSessionConnectionRecoveryScheduler()
    let machines = MachineController(
      store: InMemoryStore(), projectList: .fixture(), noticeScheduler: clock.scheduler)
    machines.cloudProvider = FakeCloudProvider()

    machines.cloudConnectionChanged(isConnected: false)
    machines.cloudConnectionChanged(isConnected: true)
    #expect(!machines.showsDeviceOffline)

    machines.cloudConnectionChanged(isConnected: false)
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()
    await awaitObserved { machines.showsDeviceOffline }

    machines.cloudConnectionChanged(isConnected: true)
    await awaitObserved { clock.pendingCount == 1 }
    clock.advance()
    await awaitObserved { !machines.showsDeviceOffline }
  }
}
