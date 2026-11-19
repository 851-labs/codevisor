import ACPKit
import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import Testing
@testable import CodevisorCore
@testable import CodevisorUI

@MainActor
@Suite("SidebarMachineGroupingDefault")
struct SidebarMachineGroupingDefaultTests {
  @Test("Going from one machine to two groups the sidebar by machine; sandboxes don't count")
  func secondMachineGroupsByMachine() {
    let account = Account(machines: [.thisMac, .sandbox])
    account.settle()
    #expect(account.grouping == nil)

    account.connect(.studio)
    account.settle()
    #expect(account.grouping == .machine)
  }

  @Test("After the switch, a later second machine leaves the user's grouping alone")
  func switchesOnlyOnce() {
    let account = Account(machines: [.thisMac])
    account.settle()
    account.connect(.studio)
    account.settle()

    account.preferences.set(SidebarGrouping.flat, forKey: SidebarGrouping.preferenceKey)
    account.disconnect(.studio)
    account.settle()
    account.connect(.studio)
    account.settle()
    #expect(account.grouping == .flat)
  }

  @Test("A grouping the user picked, even None, is kept when a second machine arrives")
  func chosenGroupingIsKept() {
    let account = Account(machines: [.thisMac])
    account.preferences.set(SidebarGrouping.flat, forKey: SidebarGrouping.preferenceKey)
    account.settle()

    account.connect(.studio)
    account.settle()
    #expect(account.grouping == .flat)
  }

  @Test("Accounts that already have two machines are never switched, even after dropping to one")
  func existingAccountsAreLeftAlone() {
    let account = Account(machines: [.thisMac, .studio])
    account.settle()
    #expect(account.grouping == nil)

    account.disconnect(.studio)
    account.settle()
    account.connect(.studio)
    account.settle()
    #expect(account.grouping == nil)
  }

  @Test("A new device that sees two machines first still switches once another device's single-machine record arrives")
  func otherDeviceRecordWins() {
    let account = Account(machines: [.thisMac, .studio])
    account.settle()

    account.receiveFromAnotherDevice(SidebarMachineGroupingDefault.Progress.oneMachine)
    account.settle()
    #expect(account.grouping == .machine)
  }

  @Test("The running watcher switches the grouping when the second machine shows up")
  func watcherReactsToRoster() async {
    let account = Account(machines: [.thisMac])
    let watcher = Task { await account.subject.run() }
    defer { watcher.cancel() }
    await awaitObserved { account.progress == .oneMachine }

    account.connect(.studio)
    await awaitObserved { account.grouping == .machine }
    #expect(account.progress == .settled)
  }
}

@MainActor
private final class Account {
  let environment = AppEnvironment.preview()
  let preferences = ClientPreferences()
  let roster = Roster()
  let subject: SidebarMachineGroupingDefault

  init(machines: [CloudMachine]) {
    roster.cloudMachines = machines
    environment.machines.cloudProvider = roster
    environment.machines.adoptLocalCloudIdentity(deviceId: CloudMachine.thisMac.deviceId)
    environment.syncClientPreferences(SidebarPreferenceKey.synced, preferences: preferences)
    subject = SidebarMachineGroupingDefault(environment: environment, preferences: preferences)
    receiveFromAnotherDevice(["pinned"], forKey: SidebarPreferenceKey.pinnedWorkspaces)
  }

  var grouping: SidebarGrouping? {
    preferences.valueIfPresent(forKey: SidebarGrouping.preferenceKey)
  }

  var progress: SidebarMachineGroupingDefault.Progress? {
    preferences.valueIfPresent(forKey: SidebarMachineGroupingDefault.preferenceKey)
  }

  func connect(_ machine: CloudMachine) {
    roster.cloudMachines.append(machine)
  }

  func disconnect(_ machine: CloudMachine) {
    roster.cloudMachines.removeAll { $0.deviceId == machine.deviceId }
  }

  func settle() {
    for _ in 0..<5 {
      guard subject.applyNextStep() != nil else { return }
    }
    Issue.record("The default kept taking steps")
  }

  func receiveFromAnotherDevice<Value: Encodable>(
    _ value: Value, forKey key: String = SidebarMachineGroupingDefault.preferenceKey
  ) {
    let json = try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    let stamp = ServerSyncTimestamp(wallMs: 1, counter: 0, deviceId: "other-device")
    environment.configSync.applyRemoteChange(
      namespace: ClientPreferenceSync.namespace, entries: [ServerSyncEntry(key: key, value: json, timestamp: stamp)])
  }
}

@MainActor
@Observable
private final class Roster: CloudMachineProviding {
  var cloudMachines: [CloudMachine] = []
  let isCloudSignedIn = true
  let isCloudRosterVerified = true

  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? { nil }
}

extension CloudMachine {
  fileprivate static let thisMac = machine("this-mac")
  fileprivate static let studio = machine("studio")
  fileprivate static let sandbox = machine(
    "sandbox", ephemeral: CloudEphemeralOrigin(provider: "tart", ownerDeviceId: "this-mac"))

  private static func machine(_ deviceId: String, ephemeral: CloudEphemeralOrigin? = nil) -> CloudMachine {
    CloudMachine(
      deviceId: deviceId, name: deviceId, publicKey: "pk-\(deviceId)", ephemeral: ephemeral, online: true,
      lastSeenAt: "2026-11-19T00:00:00.000Z")
  }
}
