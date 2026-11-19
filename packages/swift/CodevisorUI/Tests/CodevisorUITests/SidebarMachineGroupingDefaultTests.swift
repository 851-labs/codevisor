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
  func secondMachineGroupsByMachine() async {
    let account = await Account.synced(machines: [.thisMac, .sandbox])
    account.settle()
    #expect(account.grouping == nil)

    account.connect(.studio)
    account.settle()
    #expect(account.grouping == .machine)
  }

  @Test("After the switch, a later second machine leaves the user's grouping alone")
  func switchesOnlyOnce() async {
    let account = await Account.synced(machines: [.thisMac])
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
  func chosenGroupingIsKept() async {
    let account = await Account.synced(machines: [.thisMac])
    account.preferences.set(SidebarGrouping.flat, forKey: SidebarGrouping.preferenceKey)
    account.settle()

    account.connect(.studio)
    account.settle()
    #expect(account.grouping == .flat)
  }

  @Test("Accounts that already have two machines are never switched, even after dropping to one")
  func existingAccountsAreLeftAlone() async {
    let account = await Account.synced(machines: [.thisMac, .studio])
    account.settle()
    #expect(account.grouping == nil)

    account.disconnect(.studio)
    account.settle()
    account.connect(.studio)
    account.settle()
    #expect(account.grouping == nil)
  }

  @Test("Nothing is decided from preferences saved on this device until this session has synced them")
  func waitsForThisSessionsSync() async {
    let account = Account(machines: [.thisMac])
    account.preferences.set(["pinned"], forKey: SidebarPreferenceKey.pinnedWorkspaces)
    account.settle()
    #expect(account.progress == nil)

    await account.syncWithThisMac()
    account.settle()
    #expect(account.progress == .oneMachine)
  }

  @Test("Another device's settled record wins over this device's one-machine record")
  func settledBeatsOneMachine() async {
    let account = await Account.synced(machines: [.thisMac])
    account.settle()

    account.receiveFromAnotherDevice(SidebarMachineGroupingDefault.Progress.settled, wallMs: 1)
    account.connect(.studio)
    account.settle()
    #expect(account.progress == .settled)
    #expect(account.grouping == nil)
  }

  @Test("A grouping the user picked on another device wins over the automatic switch, even when it syncs later")
  func userChoiceElsewhereBeatsAutomaticGrouping() async {
    let account = await Account.synced(machines: [.thisMac])
    account.settle()
    account.connect(.studio)
    account.settle()

    account.receiveFromAnotherDevice(SidebarGrouping.flat, forKey: SidebarGrouping.preferenceKey, wallMs: 1_000)
    #expect(account.grouping == .flat)
  }

  @Test("A stale offline record of this Mac (same name) is not a second machine; an offline other machine is")
  func staleRecordOfThisMacDoesNotCount() async {
    let account = await Account.synced(machines: [.thisMac])
    account.settle()

    account.connect(.staleThisMac)
    account.settle()
    #expect(account.grouping == nil)

    account.connect(.offlineStudio)
    account.settle()
    #expect(account.grouping == .machine)
  }

  @Test("The running watcher switches the grouping when the second machine shows up, then stops")
  func watcherReactsToRoster() async {
    let account = Account(machines: [.thisMac])
    let watcher = Task { await account.subject.run() }
    await account.syncWithThisMac()
    await awaitObserved { account.progress == .oneMachine }

    account.connect(.studio)
    await watcher.value
    #expect(account.grouping == .machine)
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
  }

  static func synced(machines: [CloudMachine]) async -> Account {
    let account = Account(machines: machines)
    await account.syncWithThisMac()
    return account
  }

  var grouping: SidebarGrouping? {
    preferences.valueIfPresent(forKey: SidebarGrouping.preferenceKey)
  }

  var progress: SidebarMachineGroupingDefault.Progress? {
    preferences.valueIfPresent(forKey: SidebarMachineGroupingDefault.preferenceKey)
  }

  func syncWithThisMac() async {
    await environment.configSync.synchronize(
      machineId: CodevisorMachine.local.id, namespaces: [ClientPreferenceSync.namespace])
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
    _ value: Value, forKey key: String = SidebarMachineGroupingDefault.preferenceKey, wallMs: Int
  ) {
    let json = try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    let stamp = ServerSyncTimestamp(wallMs: wallMs, counter: 0, deviceId: "other-device")
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
  fileprivate static let staleThisMac = machine("this-mac-before-reinstall", name: "this-mac", online: false)
  fileprivate static let offlineStudio = machine("studio-asleep", online: false)
  fileprivate static let sandbox = machine(
    "sandbox", ephemeral: CloudEphemeralOrigin(provider: "tart", ownerDeviceId: "this-mac"))

  private static func machine(
    _ deviceId: String, name: String? = nil, online: Bool = true, ephemeral: CloudEphemeralOrigin? = nil
  ) -> CloudMachine {
    CloudMachine(
      deviceId: deviceId, name: name ?? deviceId, publicKey: "pk-\(deviceId)", ephemeral: ephemeral, online: online,
      lastSeenAt: "2026-11-19T00:00:00.000Z")
  }
}
