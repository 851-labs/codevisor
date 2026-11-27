import CodevisorClient
import CodevisorCore
import ComposableArchitecture
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct MachineDesktopSetupTests {
  private typealias Status = ServerDesktopStatus

  private static let bare = Status(
    state: .none, system: "Ubuntu 24.04.5 LTS", missing: ["Xvnc", "startxfce4"], packageManager: "apt",
    sudo: .passwordless)
  private static let equipped = Status(state: .none, system: "Ubuntu 24.04.5 LTS")
  private static let running = Status(state: .running, keepsRunning: true)

  @Test("A look at the machine decides what the card shows before anyone asks for anything")
  func whatTheCardShowsAtRest() async {
    let stopped = Status(state: .stopped, problem: "the desktop's session isn't up")
    let cases: [(Status, MachineDesktopSetup.Phase)] = [
      (Self.equipped, .noDesktop(setUpBefore: false)),
      (Status(state: .outdated), .noDesktop(setUpBefore: true)),
      (Self.running, .ready),
      (stopped, .failed("The desktop on hetzner isn't running.")),
    ]
    for (status, phase) in cases {
      let machine = Machine(statuses: [status])
      let store = machine.store()
      await store.send(.task)
      await store.receive(\.looked)
      #expect(store.state.phase == phase)
    }
  }

  @Test("An older server is asked to update, and any other failure is one plain sentence")
  func serversThatCannotAnswer() async {
    let older = Machine(statuses: [], failure: CodevisorServerClientError.httpStatus(404, ""))
    let olderStore = older.store()
    await olderStore.send(.task)
    await olderStore.receive(\.looked)
    #expect(olderStore.state.phase == .updateNeeded)

    let broken = Machine(
      statuses: [], failure: CodevisorServerClientError.httpStatus(500, #"{"error":"The database is locked.\ntrace"}"#))
    let brokenStore = broken.store()
    await brokenStore.send(.task)
    await brokenStore.receive(\.looked)
    #expect(brokenStore.state.phase == .failed("Couldn't check the desktop on hetzner."))
  }

  @Test("With passwordless sudo the server installs, and the card says one line per phase until the desktop is up")
  func passwordlessSetup() async {
    var installing = Self.bare
    installing.busy = "Installing packages"
    let machine = Machine(statuses: [Self.bare, installing, installing, Self.equipped], started: Self.running)
    let store = machine.store()

    await store.send(.setUpButtonTapped)
    #expect(store.state.phase == .settingUp("Checking hetzner…"))
    await store.receive(\.stepped)
    #expect(store.state.phase == .settingUp("Installing Xfce and TigerVNC…"))
    await store.receive(\.stepped)
    await machine.clock.advance(by: .seconds(2))
    await store.receive(\.stepped)
    await machine.clock.advance(by: .seconds(2))
    await store.receive(\.stepped)
    #expect(store.state.phase == .settingUp("Starting the desktop…"))
    await store.receive(\.started)
    #expect(store.state.phase == .ready)
    #expect(machine.calls.value == ["status", "install", "status", "status", "start"])
  }

  @Test(
    "Without passwordless sudo the app runs nothing as root and offers a terminal instead",
    arguments: [ServerDesktopStatus.Sudo.password, .none])
  func needsAnAdministrator(sudo: ServerDesktopStatus.Sudo) async {
    var status = Self.bare
    status.sudo = sudo
    let machine = Machine(statuses: [status])
    let store = machine.store()
    await store.send(.setUpButtonTapped)
    await store.receive(\.stepped)
    #expect(store.state.phase == .needsAdministrator("Installing packages needs an administrator on hetzner."))
    #expect(machine.calls.value == ["status"])
    #expect(store.state.terminalCommand == "codevisor desktop setup")
  }

  @Test("The terminal is named Desktop setup and is given the server's own way to run setup when the server says it")
  func terminalCommandFromTheServer() async {
    var status = Self.bare
    status.sudo = .password
    status.setupCommand = "/opt/codevisor/bin/node /opt/codevisor/cli.js desktop setup"
    let store = Machine(statuses: [status]).store()
    await store.send(.setUpButtonTapped)
    await store.receive(\.stepped)
    #expect(
      store.state.setupTerminal
        == TerminalToOpen(
          command: "/opt/codevisor/bin/node /opt/codevisor/cli.js desktop setup", name: "Desktop setup"))
  }

  @Test("Failures are plain sentences, without paths or raw output")
  func failures() async {
    var unknown = Self.bare
    unknown.packageManager = nil
    unknown.system = "Alpine Linux v3.22"
    let unknownStore = Machine(statuses: [unknown]).store()
    await unknownStore.send(.setUpButtonTapped)
    await unknownStore.receive(\.stepped)
    #expect(
      unknownStore.state.phase
        == .failed(
          "Codevisor doesn't know how to install packages on Alpine Linux v3.22. Install these on hetzner, then try again: Xvnc, startxfce4."
        ))

    var failed = Self.bare
    failed.failure = "Installing packages failed:\nReading lists\nE: Unable to locate package xfce4"
    let failedStore = Machine(statuses: [Self.bare, failed]).store()
    await failedStore.send(.setUpButtonTapped)
    await failedStore.receive(\.stepped)
    await failedStore.receive(\.stepped)
    #expect(failedStore.state.phase == .failed("Installing Xfce and TigerVNC on hetzner didn't work."))

    let missingStore = Machine(statuses: [Self.bare, Self.bare]).store()
    await missingStore.send(.setUpButtonTapped)
    await missingStore.receive(\.stepped)
    await missingStore.receive(\.stepped)
    #expect(missingStore.state.phase == .failed("Xfce and TigerVNC are still missing on hetzner after the install."))

    let reason = #"{"error":"The desktop didn't start.\nXvnc: display :1 is taken"}"#
    let downStore = Machine(statuses: [Self.equipped], startFailure: .httpStatus(500, reason)).store()
    await downStore.send(.setUpButtonTapped)
    await downStore.receive(\.stepped)
    await downStore.receive(\.started)
    #expect(downStore.state.phase == .failed("The desktop on hetzner didn't start."))
  }

  @Test("A failed install from an earlier try doesn't stop Try Again from installing")
  func tryAgainAfterAFailedInstall() async {
    var stale = Self.bare
    stale.failure = "Installing packages failed:\nE: mirror down"
    let machine = Machine(statuses: [stale, Self.equipped], started: Self.running)
    let store = machine.store()
    await store.send(.tryAgainButtonTapped)
    await store.receive(\.stepped)
    await store.receive(\.stepped)
    await store.receive(\.started)
    #expect(store.state.phase == .ready)
    #expect(machine.calls.value == ["status", "install", "start"])
  }

  @Test("An older root desktop is replaced only after a yes, and a no leaves the card as it was")
  func olderRootDesktop() async {
    var old = Self.equipped
    old.oldDesktop = .init(units: ["vncserver@1.service"])
    old.sudo = .passwordless
    let machine = Machine(statuses: [old], replaced: Self.equipped, started: Self.running)
    let store = machine.store()
    await store.send(.setUpButtonTapped)
    await store.receive(\.stepped)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.replaceOld, on: "hetzner"))
    #expect(machine.calls.value == ["status"])

    await store.send(.confirmation(.presented(.replaceOld)))
    #expect(store.state.phase == .settingUp("Removing the older desktop…"))
    await store.receive(\.stepped)
    await store.receive(\.started)
    #expect(store.state.phase == .ready)
    #expect(machine.calls.value == ["status", "replace old", "start"])

    let declining = Machine(statuses: [old])
    let declined = declining.store()
    await declined.send(.setUpButtonTapped)
    await declined.receive(\.stepped)
    await declined.send(.confirmation(.dismiss))
    #expect(declined.state.phase == .noDesktop(setUpBefore: false))
    #expect(declining.calls.value == ["status"])
  }

  @Test("Removing asks first, and a desktop Codevisor didn't set up is only unshared, with its own words")
  func removal() async {
    let machine = Machine(statuses: [Self.running], removed: Self.equipped)
    let store = machine.store()
    await store.send(.removeButtonTapped)
    #expect(store.state.confirmation == nil)
    await store.send(.task)
    await store.receive(\.looked)
    #expect(store.state.removal == .remove)

    await store.send(.removeButtonTapped)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.remove, on: "hetzner"))
    #expect(machine.calls.value == ["status"])
    await store.send(.confirmation(.presented(.remove)))
    #expect(store.state.phase == .settingUp("Removing the desktop…"))
    await store.receive(\.removed)
    #expect(store.state.phase == .noDesktop(setUpBefore: false))
    #expect(machine.calls.value == ["status", "remove"])

    var theirs = Self.running
    theirs.unmanaged = true
    theirs.keepsRunning = false
    let unmanaged = Machine(statuses: [theirs], removed: Self.equipped)
    let unmanagedStore = unmanaged.store()
    await unmanagedStore.send(.task)
    await unmanagedStore.receive(\.looked)
    #expect(unmanagedStore.state.removal == .stopSharing)
    await unmanagedStore.send(.removeButtonTapped)
    await unmanagedStore.send(.confirmation(.presented(.stopSharing)))
    await unmanagedStore.receive(\.removed)
    #expect(unmanaged.calls.value == ["status", "unshare"])
  }

  @Test("An install somebody else started is watched until it ends, and the machine's news doesn't interrupt a setup")
  func watchingAndNotInterrupting() async {
    var installing = Self.bare
    installing.busy = "Installing packages"
    let machine = Machine(statuses: [installing, Self.equipped])
    let store = machine.store()
    await store.send(.task)
    await store.receive(\.looked)
    #expect(store.state.phase == .settingUp("Installing Xfce and TigerVNC…"))
    await store.send(.machineChanged)
    #expect(machine.calls.value == ["status"])
    await machine.clock.advance(by: .seconds(2))
    await store.receive(\.looked)
    #expect(store.state.phase == .noDesktop(setUpBefore: false))
  }

  @Test("A desktop that stops while it is shown turns into Failed on the next look, and Try Again starts it")
  func aDesktopThatStopsWhileShown() async {
    let stopped = Status(state: .stopped, problem: "nothing at /root/.codevisor/run/codevisor-desktop.sock")
    let machine = Machine(statuses: [Self.running, stopped], started: Self.running)
    let store = machine.store()
    await store.send(.task)
    await store.receive(\.looked)
    #expect(store.state.phase == .ready)
    await store.send(.machineChanged)
    await store.receive(\.looked)
    #expect(store.state.phase == .failed("The desktop on hetzner isn't running."))
    #expect(!store.state.showsDesktop(sharedByMachine: true))
    await store.send(.tryAgainButtonTapped)
    await store.receive(\.stepped)
    await store.receive(\.started)
    #expect(store.state.phase == .ready)
    #expect(machine.calls.value == ["status", "status", "status", "start"])
  }

  @Test("Try Again repeats what failed: a failed look looks again, and never installs or starts anything")
  func tryAgainAfterAFailedLook() async {
    let machine = Machine(statuses: [Self.bare], failure: .httpStatus(500, #"{"error":"The server is busy."}"#))
    let store = machine.store()
    await store.send(.task)
    await store.receive(\.looked)
    #expect(store.state.phase == .failed("Couldn't check the desktop on hetzner."))
    await store.send(.tryAgainButtonTapped)
    #expect(store.state.phase == .checking)
    await store.receive(\.looked)
    #expect(machine.calls.value == ["status", "status"])
  }

  @Test("Try Again after a failed removal asks to remove again instead of setting the desktop up")
  func tryAgainAfterAFailedRemoval() async {
    var stopped = Self.running
    stopped.state = .stopped
    let machine = Machine(statuses: [stopped], removeFailure: .httpStatus(500, #"{"error":"systemctl failed."}"#))
    let store = machine.store()
    await store.send(.task)
    await store.receive(\.looked)
    await store.send(.removeButtonTapped)
    await store.send(.confirmation(.presented(.remove)))
    await store.receive(\.removed)
    #expect(store.state.phase == .failed("Couldn't remove the desktop on hetzner."))
    await store.send(.tryAgainButtonTapped)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.remove, on: "hetzner"))
    #expect(machine.calls.value == ["status", "remove"])
  }

  @Test("A removal stops a look that is still on its way, so the old answer can't overwrite it")
  func removalCancelsALookInFlight() async {
    let machine = Machine(statuses: [Self.running], removed: Self.equipped)
    let store = machine.store()
    await store.send(.task)
    await store.receive(\.looked)
    await store.send(.machineChanged)
    await store.send(.removeButtonTapped)
    await store.send(.confirmation(.presented(.remove)))
    await store.receive(\.removed)
    await store.finish()
    #expect(store.state.phase == .noDesktop(setUpBefore: false))
  }

  @Test("A machine that already shares a desktop keeps its picture when its server is older or a look fails")
  func aWorkingDesktopKeepsItsPicture() {
    var state = MachineDesktopSetup.State(machineName: "hetzner")
    for phase: MachineDesktopSetup.Phase in [.checking, .ready, .updateNeeded, .failed("timed out")] {
      state.phase = phase
      #expect(state.showsDesktop(sharedByMachine: true), "\(phase)")
      #expect(!state.showsDesktop(sharedByMachine: false), "\(phase)")
    }
    state.status = Status(state: .stopped, problem: "the desktop's session isn't up")
    state.phase = .failed("The desktop on hetzner isn't running.")
    #expect(!state.showsDesktop(sharedByMachine: true))
    state.phase = .noDesktop(setUpBefore: false)
    #expect(!state.showsDesktop(sharedByMachine: true))
  }

  @Test("A started desktop the app never sees shared ends in a sentence with Try Again, which looks again")
  func aDesktopThatNeverAppears() async {
    let machine = Machine(statuses: [Self.running])
    let store = machine.store()
    await store.send(.task)
    await store.receive(\.looked)
    #expect(store.state.awaitsItsDesktop)
    await store.send(.desktopNeverAppeared)
    #expect(
      store.state.phase == .failed("The desktop on hetzner started, but it isn't shared with Codevisor yet."))
    await store.send(.tryAgainButtonTapped)
    await store.receive(\.looked)
    #expect(store.state.phase == .ready)
    #expect(machine.calls.value == ["status", "status"])
  }

  @Test("Only the view the person used asks the confirmation, so two open views don't both show it")
  func oneAskerAtATime() async {
    let tab = UUID()
    let card = UUID()
    let store = Machine(statuses: [Self.running]).store()
    await store.send(.interacted(from: tab))
    #expect(store.state.asker == tab)
    await store.send(.interacted(from: card))
    #expect(store.state.asker == card)
  }

  @Test("A question isn't left hanging: while it waits nothing is busy, and if its view goes the other view can act")
  func aQuestionWhoseViewWentAway() async {
    var old = Self.equipped
    old.oldDesktop = .init(units: ["vncserver@1.service"])
    old.sudo = .passwordless
    let machine = Machine(statuses: [old])
    let store = machine.store()
    let tab = UUID()
    let card = UUID()
    await store.send(.interacted(from: tab))
    await store.send(.setUpButtonTapped)
    await store.receive(\.stepped)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.replaceOld, on: "hetzner"))
    #expect(!store.state.isBusy)
    #expect(store.state.phase == .asking)

    await store.send(.askerLeft(card))
    #expect(store.state.confirmation != nil)
    await store.send(.askerLeft(tab))
    #expect(store.state.confirmation == nil)
    #expect(store.state.phase == .noDesktop(setUpBefore: false))

    await store.send(.interacted(from: card))
    await store.send(.setUpButtonTapped)
    await store.receive(\.stepped)
    #expect(store.state.asker == card)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.replaceOld, on: "hetzner"))
  }

  @Test("A running desktop Codevisor didn't set up isn't shown as ready while setup asks to replace it")
  func askingAboutARunningUnmanagedDesktop() async {
    var theirs = Self.running
    theirs.unmanaged = true
    theirs.keepsRunning = false
    let store = Machine(statuses: [theirs]).store()
    await store.send(.setUpButtonTapped)
    await store.receive(\.stepped)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.replaceUnmanaged, on: "hetzner"))
    #expect(store.state.phase == .asking)
    #expect(!store.state.showsDesktop(sharedByMachine: true))
    #expect(!store.state.awaitsItsDesktop)
    await store.send(.machineChanged)
    await store.receive(\.looked)
    #expect(store.state.phase == .asking)
  }

  @Test("A renamed machine keeps its store, so a shown question stays, and new words use the new name")
  func renaming() async {
    let store = Machine(statuses: [Self.running]).store()
    await store.send(.task)
    await store.receive(\.looked)
    await store.send(.removeButtonTapped)
    await store.send(.machineRenamed("build-box"))
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.remove, on: "hetzner"))
    #expect(store.state.machineName == "build-box")
    await store.send(.confirmation(.dismiss))
    await store.send(.removeButtonTapped)
    #expect(store.state.confirmation == MachineDesktopDialogs.dialog(.remove, on: "build-box"))
  }

  @Test("A rename refreshes the sentence the card shows for the machine's desktop")
  func renamingRefreshesTheSentence() async {
    let stopped = Status(state: .stopped, problem: "the desktop's session isn't up")
    let store = Machine(statuses: [stopped]).store()
    await store.send(.task)
    await store.receive(\.looked)
    await store.send(.machineRenamed("build-box"))
    #expect(store.state.phase == .failed("The desktop on build-box isn't running."))
  }

}

@MainActor
private struct Machine {
  let calls = LockIsolated<[String]>([])
  let clock = TestClock()
  let statuses: LockIsolated<[ServerDesktopStatus]>
  var failure: CodevisorServerClientError?
  var removed: ServerDesktopStatus?
  var replaced: ServerDesktopStatus?
  var started: ServerDesktopStatus?
  var startFailure: CodevisorServerClientError?
  var removeFailure: CodevisorServerClientError?

  init(
    statuses: [ServerDesktopStatus], failure: CodevisorServerClientError? = nil, removed: ServerDesktopStatus? = nil,
    replaced: ServerDesktopStatus? = nil, started: ServerDesktopStatus? = nil,
    startFailure: CodevisorServerClientError? = nil, removeFailure: CodevisorServerClientError? = nil
  ) {
    self.statuses = LockIsolated(statuses)
    self.failure = failure
    self.removed = removed
    self.replaced = replaced
    self.started = started
    self.startFailure = startFailure
    self.removeFailure = removeFailure
  }

  func store() -> TestStoreOf<MachineDesktopSetup> {
    let store = TestStore(initialState: MachineDesktopSetup.State(machineName: "hetzner")) {
      MachineDesktopSetup()
    } withDependencies: {
      $0.continuousClock = clock
      $0[MachineDesktopClient.self] = client
    }
    store.exhaustivity = .off
    return store
  }

  private var client: MachineDesktopClient {
    let next: @Sendable (String) throws -> ServerDesktopStatus = { [calls, statuses, failure] call in
      calls.withValue { $0.append(call) }
      if let failure { throw failure }
      return statuses.withValue { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
    return MachineDesktopClient(
      status: { try next("status") },
      installPackages: { try next("install") },
      replaceOld: { [calls, replaced, statuses] in
        calls.withValue { $0.append("replace old") }
        return replaced ?? statuses.value[0]
      },
      start: { [calls, started, startFailure, statuses] _ in
        calls.withValue { $0.append("start") }
        if let startFailure { throw startFailure }
        return started ?? statuses.value[0]
      },
      remove: { [calls, removed, removeFailure, statuses] unsharing in
        calls.withValue { $0.append(unsharing ? "unshare" : "remove") }
        if let removeFailure { throw removeFailure }
        return removed ?? statuses.value[0]
      })
  }
}
