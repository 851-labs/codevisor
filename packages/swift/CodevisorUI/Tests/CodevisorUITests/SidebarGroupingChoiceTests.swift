import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import Testing
@testable import CodevisorCore
@testable import CodevisorUI

@MainActor
@Suite("SidebarGroupingChoice", .timeLimit(.minutes(1)))
struct SidebarGroupingChoiceTests {
  @Test("With no saved grouping, the sidebar groups by machine while the account has two machines")
  func followsMachineCount() {
    let account = Account(machines: [.thisMac])
    #expect(account.choice.effective == .flat)

    account.connect(.studio)
    #expect(account.choice.effective == .machine)

    account.disconnect(.studio)
    #expect(account.choice.effective == .flat)
  }

  @Test("A saved grouping, even None, wins over the machine count")
  func savedGroupingWins() {
    let account = Account(machines: [.thisMac, .studio])
    account.choice.selection.wrappedValue = .flat
    #expect(account.choice.effective == .flat)

    account.choice.selection.wrappedValue = .project
    account.disconnect(.studio)
    #expect(account.choice.effective == .project)
  }

  @Test("With a saved grouping, machine changes don't invalidate the grouping")
  func savedGroupingIgnoresMachineChanges() {
    let account = Account(machines: [.thisMac])
    account.choice.save(.flat)
    let invalidated = TestSignal()
    withObservationTracking {
      _ = account.choice.effective
    } onChange: {
      invalidated.signal()
    }

    account.connect(.studio)
    #expect(invalidated.value == 0)
  }

  @Test("A saved grouping this build can't read shows None, as before, not the machine default")
  func unreadableSavedGroupingShowsNone() {
    let account = Account(machines: [.thisMac, .studio])
    account.preferences.set("a-grouping-from-a-newer-build", forKey: SidebarGrouping.preferenceKey)
    #expect(account.choice.effective == .flat)
  }

  @Test("Picking the grouping that is already shown keeps it when the machine count changes")
  func pickingTheShownGroupingSavesIt() {
    let account = Account(machines: [.thisMac, .studio])
    account.choice.selection.wrappedValue = account.choice.effective

    account.disconnect(.studio)
    #expect(account.choice.effective == .machine)
  }

  @Test("Sandboxes don't count as machines")
  func sandboxesDoNotCount() {
    let account = Account(machines: [.thisMac, .sandbox])
    #expect(account.choice.effective == .flat)
  }

  @Test("At launch, the last result shows until the cloud account has loaded, so the sidebar doesn't regroup")
  func launchShowsTheRememberedResult() {
    let lastSession = Account(machines: [.thisMac, .studio])
    #expect(lastSession.choice.effective == .machine)

    let launch = Account(machines: [], preferences: lastSession.preferences, cloudHasLoaded: false)
    #expect(launch.choice.effective == .machine)

    launch.finishLoadingCloud(machines: [.thisMac, .studio])
    #expect(launch.choice.effective == .machine)
  }

  @Test("A second Mac with this Mac's name counts as a second machine, online or asleep")
  func sameNamedMacCountsWhetherOnlineOrNot() {
    let account = Account(machines: [.thisMac, .secondMacWithSameName])
    #expect(account.choice.effective == .machine)

    account.sleep(.secondMacWithSameName)
    #expect(account.choice.effective == .machine)
  }

  @Test("This Mac's own cloud record is never a second machine, even renamed and before the Mac knows its identity")
  func ownRecordIsNotASecondMachine() {
    let account = Account(machines: [.thisMacRenamedInCloud], knowsOwnIdentity: false)
    #expect(account.choice.effective == .flat)

    account.learnOwnIdentity()
    #expect(account.choice.effective == .flat)
  }

  @Test("Signing out returns the default to None")
  func signingOutReturnsToNone() {
    let account = Account(machines: [.thisMac, .studio])
    account.signOut()
    #expect(account.choice.effective == .flat)
  }

  @Test("The count follows the account on its own once it is being followed")
  func followsWithoutBeingAsked() async {
    let account = Account(machines: [.thisMac])
    account.cloud.cloudMachines.append(.studio)
    await awaitObserved { account.choice.effective == .machine }
  }
}

@MainActor
private final class Account {
  let environment = AppEnvironment.preview()
  let preferences: ClientPreferences
  let cloud = Cloud()
  let machineCount: AccountMachineCount

  init(
    machines: [CloudMachine], preferences: ClientPreferences = ClientPreferences(), cloudHasLoaded: Bool = true,
    knowsOwnIdentity: Bool = true
  ) {
    self.preferences = preferences
    cloud.cloudMachines = machines
    cloud.isCloudSignedIn = cloudHasLoaded
    cloud.hasCompletedCloudBootstrap = cloudHasLoaded
    environment.machines.cloudProvider = cloud
    machineCount = AccountMachineCount(machines: environment.machines, preferences: preferences)
    if knowsOwnIdentity { environment.machines.adoptLocalCloudIdentity(deviceId: CloudMachine.thisMac.deviceId) }
    machineCount.follow()
  }

  var choice: SidebarGroupingChoice {
    SidebarGroupingChoice(machineCount: machineCount, preferences: preferences)
  }

  func connect(_ machine: CloudMachine) {
    cloud.cloudMachines.append(machine)
    machineCount.follow()
  }

  func disconnect(_ machine: CloudMachine) {
    cloud.cloudMachines.removeAll { $0.deviceId == machine.deviceId }
    machineCount.follow()
  }

  func sleep(_ machine: CloudMachine) {
    var asleep = machine
    asleep.online = false
    cloud.cloudMachines = cloud.cloudMachines.map { $0.deviceId == machine.deviceId ? asleep : $0 }
    machineCount.follow()
  }

  func finishLoadingCloud(machines: [CloudMachine]) {
    cloud.cloudMachines = machines
    cloud.isCloudSignedIn = true
    cloud.hasCompletedCloudBootstrap = true
    environment.machines.adoptLocalCloudIdentity(deviceId: CloudMachine.thisMac.deviceId)
    machineCount.follow()
  }

  func learnOwnIdentity() {
    environment.machines.adoptLocalCloudIdentity(deviceId: CloudMachine.thisMac.deviceId)
    machineCount.follow()
  }

  func signOut() {
    cloud.isCloudSignedIn = false
    cloud.cloudMachines = []
    machineCount.follow()
  }
}

@MainActor
@Observable
private final class Cloud: CloudMachineProviding {
  var cloudMachines: [CloudMachine] = []
  var isCloudSignedIn = true
  var hasCompletedCloudBootstrap = true
  let isCloudRosterVerified = true

  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? { nil }
}

extension CloudMachine {
  fileprivate static let thisMac = machine("this-mac", name: CodevisorMachine.local.name)
  fileprivate static let thisMacRenamedInCloud = machine("this-mac", name: "Renamed In Settings")
  fileprivate static let studio = machine("studio", name: "Studio")
  fileprivate static let secondMacWithSameName = machine("second-mac", name: CodevisorMachine.local.name)
  fileprivate static let sandbox = machine(
    "sandbox", name: "Sandbox", ephemeral: CloudEphemeralOrigin(provider: "tart", ownerDeviceId: "this-mac"))

  private static func machine(
    _ deviceId: String, name: String, online: Bool = true, ephemeral: CloudEphemeralOrigin? = nil
  ) -> CloudMachine {
    CloudMachine(
      deviceId: deviceId, name: name, publicKey: "pk-\(deviceId)", ephemeral: ephemeral, online: online,
      lastSeenAt: "2026-11-19T00:00:00.000Z")
  }
}
