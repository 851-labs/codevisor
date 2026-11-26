import CodevisorClient
import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorUI

@MainActor
@Suite("SidebarGroupingChoice")
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

  @Test("A second Mac with this Mac's name counts as a second machine")
  func sameNamedMacsCountAsTwo() {
    let account = Account(machines: [.thisMac, .secondMacWithSameName])
    #expect(account.choice.effective == .machine)
  }

  @Test("A stale offline record of this Mac doesn't count as a second machine")
  func staleRecordOfThisMacDoesNotCount() {
    let account = Account(machines: [.thisMac, .staleRecordOfThisMac])
    #expect(account.choice.effective == .flat)
  }
}

@MainActor
private final class Account {
  let environment = AppEnvironment.preview()
  let preferences = ClientPreferences()
  let roster = Roster()

  init(machines: [CloudMachine]) {
    roster.cloudMachines = machines
    environment.machines.cloudProvider = roster
    environment.machines.adoptLocalCloudIdentity(deviceId: CloudMachine.thisMac.deviceId)
  }

  var choice: SidebarGroupingChoice {
    SidebarGroupingChoice(machines: environment.machines, preferences: preferences)
  }

  func connect(_ machine: CloudMachine) {
    roster.cloudMachines.append(machine)
  }

  func disconnect(_ machine: CloudMachine) {
    roster.cloudMachines.removeAll { $0.deviceId == machine.deviceId }
  }
}

@MainActor
private final class Roster: CloudMachineProviding {
  var cloudMachines: [CloudMachine] = []
  let isCloudSignedIn = true
  let isCloudRosterVerified = true

  func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? { nil }
}

extension CloudMachine {
  fileprivate static let thisMac = machine("this-mac", name: CodevisorMachine.local.name)
  fileprivate static let studio = machine("studio", name: "Studio")
  fileprivate static let secondMacWithSameName = machine("second-mac", name: CodevisorMachine.local.name)
  fileprivate static let staleRecordOfThisMac = machine(
    "this-mac-before-reinstall", name: CodevisorMachine.local.name, online: false)
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
