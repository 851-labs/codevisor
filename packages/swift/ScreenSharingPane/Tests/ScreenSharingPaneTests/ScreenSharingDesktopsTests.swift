import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import ScreenSharingPane

@MainActor
@Suite("The phone's Desktop on the shared connection", .timeLimit(.minutes(1)))
struct ScreenSharingDesktopsTests {
  @Test(
    "Switching between two Desktop tabs on one machine keeps the same share: one start, no stop",
    arguments: [true, false])
  func tabSwitchSendsNothing(newTabAppearsFirst: Bool) async {
    let harness = DesktopsHarness()
    let model = harness.model()
    let first = harness.show(model)
    let session = await harness.goLive(model)

    if newTabAppearsFirst { harness.show(harness.model()) }
    model?.viewRemoved(first)
    if !newTabAppearsFirst { harness.show(harness.model()) }

    #expect(harness.model() === model)
    #expect(model?.isViewing == true && model?.session === session)
    #expect(harness.host.starts.count == 1 && harness.host.stops.isEmpty)
  }

  @Test("Open Desktop asks to take over under the phone's name; a tab that only comes on screen attaches")
  func onlyOpenDesktopOpens() async {
    let (opened, shown) = (DesktopsHarness(), DesktopsHarness())
    let openedModel = opened.model()
    let pane = UUID()
    openedModel?.openedByUser(pane: pane)
    opened.show(openedModel, pane: pane)
    await opened.goLive(openedModel)
    shown.show(shown.model())
    await shown.goLive(shown.model())

    #expect(opened.host.starts.map(\.intent) == [.open])
    #expect(shown.host.starts.map(\.intent) == [.attach])
    #expect(opened.host.starts.first?.app?.name == DesktopsHarness.appName)
  }

  @Test(
    "An Open Desktop whose tab didn't come on screen, or came too late, doesn't turn a tab's connect into a takeover",
    arguments: [false, true])
  func staleOpenDoesNotTakeOver(sameTabTooLate: Bool) async {
    let harness = DesktopsHarness()
    let model = harness.model()
    let opened = UUID()
    model?.openedByUser(pane: opened)

    if sameTabTooLate { harness.clock.advance(by: ScreenSharingConnectionDeadlines.pendingOpen + .seconds(1)) }
    harness.show(model, pane: sameTabTooLate ? opened : UUID())
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("Coming back from the background reconnects the share as an attach")
  func returnFromBackgroundReconnects() async {
    let harness = DesktopsHarness()
    let model = harness.model()
    harness.show(model)
    let before = await harness.goLive(model)

    harness.desktops.returnedToForeground()
    let after = await harness.goLive(model)

    #expect(before.isClosed && model?.session === after)
    #expect(harness.host.starts.map(\.intent) == [.attach, .attach])
  }

  @Test("An old host with no synced workspace on the machine yet connects by itself once one appears")
  func connectsWhenAWorkspaceAppears() async {
    let harness = DesktopsHarness(host: .old())
    harness.world.setLiveWorkspaces([])
    let model = harness.model(showing: UUID())
    harness.show(model)
    await awaitObserved { model?.state == .failed(.noWorkspace) }

    let created = UUID()
    harness.world.setLiveWorkspaces([created])
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.workspaceId) == [created])
  }

  @Test("An old host is started under the workspace on screen, and under another live one once that is archived")
  func oldHostFollowsALiveWorkspace() async {
    let harness = DesktopsHarness(host: .old())
    let (kept, shown) = (UUID(), UUID())
    harness.world.setLiveWorkspaces([kept, shown])
    let model = harness.model(showing: shown)
    harness.show(model)
    let session = await harness.goLive(model)

    harness.world.setLiveWorkspaces([kept])
    session.host.report(connection: "failed")
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.workspaceId) == [shown, kept])
    #expect(harness.host.registeredPanes.map(\.workspaceId) == [shown, kept])
    #expect(harness.host.starts.allSatisfy { $0.app == nil })
  }

  @Test("A Desktop that couldn't reach its machine connects by itself when the machine is back online")
  func connectsWhenTheMachineComesBack() async {
    let harness = DesktopsHarness()
    harness.world.isReady = false
    harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    let model = harness.model()
    harness.show(model)
    await awaitObserved { model?.state == .failed(.cantReach) }
    #expect(model?.failure?.action == .tryAgain)

    harness.host.answerEvery(.capabilities, nil)
    harness.world.isReady = true
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("Removing the machine ends its share and says so at once; adding it back gives a fresh Desktop")
  func machineRemoved() async {
    let harness = DesktopsHarness()
    let model = harness.model()
    harness.show(model)
    await harness.goLive(model)

    harness.world.machineName = nil
    await awaitObserved { model?.isEnded == true && harness.host.stops.count == 1 }
    #expect(harness.model() == nil, "no new Desktop, so no spinner, while the machine is gone")
    harness.world.machineName = "croissant"

    #expect(harness.model() !== model)
  }

  @Test("The display picked on the phone moves the share there and is the machine's display after a relaunch")
  func pickedDisplayIsRemembered() async {
    let harness = DesktopsHarness()
    harness.host.displays = [FakeHost.display, FakeHost.second]
    let model = harness.model()
    harness.show(model)
    await harness.goLive(model)

    model?.select(displayId: FakeHost.second.id)
    await harness.goLive(model)
    let relaunched = harness.model(in: harness.makeDesktops(), seedDisplayId: FakeHost.display.id)
    harness.show(relaunched)
    await harness.goLive(relaunched)

    #expect(harness.host.starts.map(\.displayId) == [nil, FakeHost.second.id, FakeHost.second.id])
    #expect(model?.selectedDisplay == FakeHost.second)
  }

  @Test("Until a display is picked for the machine, the one saved on the pane is asked for")
  func paneDisplaySeedsTheChoice() async {
    let harness = DesktopsHarness()
    harness.host.displays = [FakeHost.display, FakeHost.second]
    let model = harness.model(seedDisplayId: FakeHost.second.id)
    harness.show(model)
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.displayId) == [FakeHost.second.id])
  }

  @Test("A Linux desktop, which the phone has no viewer for, says it can only be viewed from a Mac and offers no retry")
  func linuxDesktopIsMacOnly() async {
    let harness = DesktopsHarness()
    harness.host.provider = "vnc"
    let model = harness.model()
    harness.show(model)
    await awaitObserved { model?.state == .failed(.unsupportedOnThisDevice) }

    #expect(model?.failure?.sentence == "croissant's desktop can only be viewed from a Mac.")
    #expect(model?.failure?.action == nil)
    #expect(harness.host.starts.isEmpty)
  }

  @Test("When another device takes the desktop, the phone says who is viewing, and View here takes it back")
  func viewHereTakesTheDesktopBack() async throws {
    let harness = DesktopsHarness()
    let model = try #require(harness.model())
    harness.show(model)
    await harness.goLive(model)

    harness.host.answerNext(
      .heartbeat, .reply(status: "failed", reason: "taken-over", holderName: "Alexandru's MacBook Pro"))
    await harness.heartbeat()
    await awaitObserved { model.failure != nil }
    #expect(model.failure?.sentence == "Now viewing on Alexandru's MacBook Pro.")
    #expect(model.failure?.action == .viewHere)
    #expect(harness.host.starts.count == 1, "the phone doesn't take the desktop back by itself")

    model.viewHere()
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.intent) == [.attach, .open])
  }

  @Test(
    "A tab that comes on screen while another device is viewing says so and offers View here instead of taking over")
  func passiveTabDoesNotTakeOver() async throws {
    let harness = DesktopsHarness()
    harness.host.answerNext(.start, .reply(status: "busy", reason: "in-use", holderName: "Alexandru's MacBook Pro"))
    let model = try #require(harness.model())
    harness.show(model)
    await awaitObserved { model.failure != nil }

    #expect(model.failure?.sentence == "In use on Alexandru's MacBook Pro.")
    #expect(model.failure?.action == .viewHere)
    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("Touches control the share being shown, and control is given up when the Desktop leaves the screen")
  func touchesFollowTheShare() async throws {
    let harness = DesktopsHarness()
    let model = try #require(harness.model())
    let view = harness.show(model)
    let first = harness.controlLog(of: await harness.goLive(model))
    let point = ScreenSharingPointer(x: 0.5, y: 0.5)

    model.tap(at: point, location: .zero, time: 0)
    await awaitObserved { first.messages.count == 1 }
    guard case .request(let request)? = first.messages.first else {
      Issue.record("The first touch should ask the Mac for control")
      return
    }
    let lease = UUID()
    harness.media.sessions[0].host.control?.send(.grant(request: request, lease: lease))
    await awaitObserved { model.control?.state == .controlling }
    harness.hide(view, of: model)
    await awaitObserved { first.messages.last == .release(lease: lease) }
    #expect(model.control?.state == .idle)

    harness.showAgain(view, of: model)
    model.reconnect()
    let second = harness.controlLog(of: await harness.goLive(model))
    model.tap(at: point, location: .zero, time: 1)
    await awaitObserved { second.messages.count == 1 }

    #expect(first.messages.last == .release(lease: lease), "nothing reaches the share that was replaced")
  }

  @Test("The keyboard stays up while the app is briefly inactive and closes when the Desktop tab closes")
  func keyboardClosesWithTheTab() throws {
    let harness = DesktopsHarness()
    let model = try #require(harness.model())
    let view = harness.show(model)
    model.keyboardShown = true

    harness.hide(view, of: model)
    #expect(model.keyboardShown)
    model.viewRemoved(view)
    #expect(!model.keyboardShown)
  }
}
