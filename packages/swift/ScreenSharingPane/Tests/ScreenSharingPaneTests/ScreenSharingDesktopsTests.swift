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
    openedModel?.openedByUser()
    opened.show(openedModel)
    await opened.goLive(openedModel)
    shown.show(shown.model())
    await shown.goLive(shown.model())

    #expect(opened.host.starts.map(\.intent) == [.open])
    #expect(shown.host.starts.map(\.intent) == [.attach])
    #expect(opened.host.starts.first?.app?.name == DesktopsHarness.appName)
  }

  @Test("An old host is started under the workspace on screen, and under another live one once that is archived")
  func oldHostFollowsALiveWorkspace() async {
    let harness = DesktopsHarness(host: .old())
    let (kept, shown) = (UUID(), UUID())
    harness.world.liveWorkspaces = [kept, shown]
    let model = harness.model(showing: shown)
    harness.show(model)
    let session = await harness.goLive(model)

    harness.world.liveWorkspaces = [kept]
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

    harness.host.answerEvery(.capabilities, nil)
    harness.world.isReady = true
    await harness.goLive(model)

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("Removing the machine ends its share, and adding it back gives a fresh Desktop")
  func machineRemoved() async {
    let harness = DesktopsHarness()
    let model = harness.model()
    harness.show(model)
    await harness.goLive(model)

    harness.world.machineName = nil
    await awaitObserved { model?.state == .off && harness.host.stops.count == 1 }
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

  @Test("A Linux desktop, which the phone has no viewer for, says it can only be viewed from a Mac")
  func linuxDesktopIsMacOnly() async {
    let harness = DesktopsHarness()
    harness.host.provider = "vnc"
    let model = harness.model()
    harness.show(model)
    await awaitObserved { model?.state == .failed(.unsupportedOnThisDevice) }

    #expect(harness.host.starts.isEmpty)
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
    model.setOnScreen(false, for: view)
    await awaitObserved { first.messages.last == .release(lease: lease) }
    #expect(model.control?.state == .idle)

    model.setOnScreen(true, for: view)
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

    model.setOnScreen(false, for: view)
    #expect(model.keyboardShown)
    model.viewRemoved(view)
    #expect(!model.keyboardShown)
  }
}
