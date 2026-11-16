import AppKit
import CodevisorCore
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("Keyboard and mouse on a machine's desktop", .timeLimit(.minutes(1)))
struct ScreenSharingDesktopControlTests {
  private typealias Fixture = ScreenSharingConnectionsFixture

  @Test("A tab or window that comes on screen gets control without a click; the preview never does")
  func givesControlToAShownTabOrWindowNeverThePreview() async throws {
    let host = Host()
    let preview = host.fixture.surface(.watcher)
    preview.show()
    await awaitObserved { preview.snapshot.endpoint != nil }
    preview.surface.takeControl()
    #expect(host.requests.isEmpty && preview.snapshot.control == nil)

    let window = host.fixture.surface(.window)
    window.show()
    let lease = await host.grant()
    await host.controls(window)

    #expect(preview.snapshot.control == nil)
    #expect(host.sent == [.request(id: host.requests[0])], "lease \(lease) is asked for once")
  }

  @Test("Control is asked for once the picture is live, not when the session opens")
  func asksOnlyOnceLive() async throws {
    let host = Host()
    host.session.deliversVideo = false
    var statesAtRequest: [ScreenSharingConnectionState?] = []
    host.session.controlChannel.onSend = { [fixture = host.fixture] in
      if case .request = $0 { statesAtRequest.append(try? fixture.connection.state) }
    }
    let tab = host.fixture.surface(.tab)
    tab.show()
    await awaitObserved { tab.snapshot.endpoint != nil && tab.snapshot.control != nil }
    #expect(tab.snapshot.connection != .live)

    host.session.deliverFrame()
    await awaitObserved { host.requests.count == 1 }

    #expect(statesAtRequest == [.live], "a Mac host refuses control until it has video")
  }

  @Test("A host that is not ready for control on the first frame is asked again, and control arrives")
  func asksAgainWhenTheHostWasNotReady() async throws {
    let host = Host()
    let tab = host.fixture.surface(.tab)
    tab.show()
    await awaitObserved { host.requests.count == 1 }
    host.session.controlChannel.deliver(
      .denied(request: host.requests[0], reason: "Wait for live video before requesting control."))
    await host.fixture.controlClock.waitForSleep(ControlLease.refusalRetryDelay)
    #expect(tab.snapshot.control?.message == nil, "no banner for a refusal that is retried")
    #expect(host.requests.count == 1)

    host.fixture.controlClock.advance(by: ControlLease.refusalRetryDelay)
    await awaitObserved { host.requests.count == 2 }
    await host.grant()
    await host.controls(tab)
  }

  @Test("Clicking into another surface moves control locally: nothing goes to the host and both keep their picture")
  func movesControlWithoutTheHost() async throws {
    let host = Host()
    let (window, tab) = (host.fixture.surface(.window), host.fixture.surface(.tab))
    window.show()
    await host.grant()
    await host.controls(window)
    tab.show()
    #expect(tab.snapshot.control == nil, "a surface that comes on screen leaves the one with control alone")
    let (windowView, tabView) = (window.surface.videoView(), tab.surface.videoView())

    tab.surface.takeControl()

    #expect(tab.snapshot.hasControl && window.snapshot.control == nil, "both learn it in the same turn")
    #expect(host.sent.count == 1, "no release and no second request")
    #expect(host.fixture.fake(for: tab)?.inputActive == true && host.fixture.fake(for: window)?.inputActive == false)
    #expect(window.surface.videoView() === windowView && tab.surface.videoView() === tabView)
    #expect(host.fixture.fake(for: window)?.stopped == false)
  }

  @Test("A surface the user opens takes control when it comes on screen, without a click and without the host")
  func givesControlToAnOpenedSurface() async throws {
    let host = Host()
    let (tab, window) = (host.fixture.surface(.tab), host.fixture.surface(.window))
    tab.show()
    await host.grant()
    await host.controls(tab)

    let (tabWindow, desktopWindow) = (NSWindow(), NSWindow())
    tabWindow.contentView?.addSubview(try #require(tab.surface.videoView()))
    desktopWindow.contentView?.addSubview(try #require(window.surface.videoView()))
    #expect(tabWindow.firstResponder !== tab.surface.videoView(), "a surface that merely shows takes no focus")

    window.surface.openedByUser()
    #expect(tab.snapshot.hasControl, "not before it is on screen")
    window.show()

    #expect(window.snapshot.hasControl && tab.snapshot.control == nil && host.sent.count == 1)
    #expect(desktopWindow.firstResponder === window.surface.videoView(), "its picture gets the keyboard, no click")
    window.hide()
    window.show()
    #expect(tab.snapshot.hasControl, "coming back on screen later does not take control again")
  }

  @Test("Hiding the surface with control gives it to a surface still on screen, or back to the host if none is")
  func passesControlOnWhenItsSurfaceHides() async throws {
    let host = Host()
    let (window, tab) = (host.fixture.surface(.window), host.fixture.surface(.tab))
    window.show()
    let lease = await host.grant()
    await host.controls(window)
    tab.show()

    window.hide()
    #expect(tab.snapshot.hasControl && window.snapshot.control == nil, "the tab takes over locally")
    #expect(host.fixture.fake(for: tab)?.inputActive == true && host.sent.count == 1)

    tab.hide()
    await awaitObserved { host.sent.last == .release(lease: lease) }
    #expect(tab.snapshot.control == nil && window.snapshot.control == nil)

    tab.show()
    await awaitObserved { host.requests.count == 2 }
  }

  @Test("View-only is one setting per machine: it gives control back, clicks stop taking it, and it is remembered")
  func keepsViewOnlyPerMachine() async throws {
    let host = Host()
    let (window, tab) = (host.fixture.surface(.window), host.fixture.surface(.tab))
    window.show()
    tab.show()
    let lease = await host.grant()
    await awaitObserved { window.snapshot.hasControl }

    tab.surface.setMode(.view)
    await awaitObserved { host.sent.last == .release(lease: lease) }
    #expect(window.snapshot.mode == .view && tab.snapshot.mode == .view)
    #expect(host.fixture.preferences.viewOnly(machineId: Fixture.machineId))
    window.surface.takeControl()
    #expect(host.requests.count == 1 && host.fixture.fake(for: window)?.inputActive == false)
    #expect(window.snapshot.control == nil && tab.snapshot.control == nil, "View-only leaves nobody in control")

    tab.surface.setMode(.control)
    await awaitObserved { host.requests.count == 2 }
    #expect(tab.snapshot.control != nil && window.snapshot.control == nil, "the surface that asked gets it")
    #expect(!host.fixture.preferences.viewOnly(machineId: Fixture.machineId))
  }

  @Test("A surface the user opens before the picture is live gets the keyboard when it goes live, without a click")
  func givesTheKeyboardWhenAnOpenedSurfaceGoesLive() async throws {
    let host = Host()
    host.session.deliversVideo = false
    let window = host.fixture.surface(.window)
    window.surface.openedByUser()
    window.show()
    await awaitObserved { window.snapshot.endpoint != nil }
    let desktopWindow = NSWindow()
    desktopWindow.contentView?.addSubview(try #require(window.surface.videoView()))
    #expect(desktopWindow.firstResponder !== window.surface.videoView(), "not before the picture is live")

    host.session.deliverFrame()
    await awaitObserved { host.requests.count == 1 }

    #expect(desktopWindow.firstResponder === window.surface.videoView())
  }

  @Test("A surface the user opens gets the keyboard once its picture reaches a window, if it was not in one yet")
  func givesTheKeyboardWhenThePictureReachesAWindow() async throws {
    let host = Host()
    let window = host.fixture.surface(.window)
    window.surface.openedByUser()
    window.show()
    await awaitObserved { host.requests.count == 1 }
    let video = try #require(window.surface.videoView())
    #expect(video.window == nil)

    let desktopWindow = NSWindow()
    desktopWindow.contentView?.addSubview(video)

    #expect(desktopWindow.firstResponder === video)
  }

  @Test("A mode taken for this connection goes back to the saved one when the connection turns off")
  func restoresTheSavedModeWhenTheConnectionTurnsOff() async throws {
    let host = Host()
    let tab = host.fixture.surface(.tab)
    tab.surface.setMode(.view)
    tab.show()
    await awaitObserved { tab.snapshot.connection == .live }
    tab.surface.controlForThisSession()
    #expect(tab.snapshot.mode == .control)

    tab.hide()
    await host.fixture.clock.waitForSleep(ScreenSharingConnectionDeadlines.unseenDebounce)
    host.fixture.clock.advance(by: ScreenSharingConnectionDeadlines.unseenDebounce)
    await host.fixture.clock.waitForSleep(ScreenSharingConnectionDeadlines.linger)
    host.fixture.clock.advance(by: ScreenSharingConnectionDeadlines.linger)
    await host.fixture.settle(.off)

    await awaitObserved { tab.snapshot.mode == .view }
    #expect(host.fixture.preferences.viewOnly(machineId: Fixture.machineId))
  }

  @Test("A system key pressed in View takes control for this session and leaves the saved setting on View")
  func leavesTheSavedModeAloneForASystemKey() async throws {
    let host = Host()
    let tab = host.fixture.surface(.tab)
    tab.surface.setMode(.view)
    tab.show()
    await awaitObserved { tab.snapshot.endpoint != nil }
    #expect(host.requests.isEmpty)

    tab.surface.controlForThisSession()
    await awaitObserved { host.requests.count == 1 }

    #expect(tab.snapshot.mode == .control && tab.snapshot.control != nil)
    #expect(host.fixture.preferences.viewOnly(machineId: Fixture.machineId), "the machine is still saved as View")
  }

  @Test("Dynamic Resolution is one value per machine and does not change when control moves")
  func keepsDynamicResolutionPerMachine() async throws {
    let host = Host()
    let (window, tab) = (host.fixture.surface(.window), host.fixture.surface(.tab))
    window.show()
    tab.show()
    await host.grant()
    await awaitObserved { window.snapshot.hasControl }

    window.surface.setDynamicResolution(true)
    #expect(window.snapshot.dynamicResolution && tab.snapshot.dynamicResolution)
    #expect(host.fixture.preferences.dynamicResolution(machineId: Fixture.machineId))
    tab.surface.takeControl()
    window.surface.takeControl()

    #expect(window.snapshot.endpoint?.dynamicResolution == true && tab.snapshot.dynamicResolution)
  }

  @Test("The surface with control sizes the host desktop, else the largest tab or window, never the preview")
  func sizesTheDesktopWithOneSurface() async throws {
    let host = Host()
    let (preview, tab, window) = (
      host.fixture.surface(.watcher), host.fixture.surface(.tab), host.fixture.surface(.window)
    )
    tab.surface.setDynamicResolution(true)
    preview.show()
    await awaitObserved { preview.snapshot.endpoint != nil }
    _ = preview.surface.videoView()
    host.fixture.fake(for: preview)?.onSizeChanged?(CGSize(width: 2000, height: 1200), 1)
    #expect(host.session.desktopSizeRequests.isEmpty, "a preview alone never sizes the desktop")

    tab.surface.setMode(.view)
    tab.show()
    window.show()
    _ = (tab.surface.videoView(), window.surface.videoView())
    host.fixture.fake(for: tab)?.onSizeChanged?(CGSize(width: 640, height: 400), 1)
    host.fixture.fake(for: window)?.onSizeChanged?(CGSize(width: 800, height: 600), 1)
    #expect(host.session.desktopSizeRequests.last == [800, 600], "with no control, the largest one on screen")

    tab.surface.setMode(.control)
    #expect(host.session.desktopSizeRequests.last == [640, 400], "the surface with control decides")
  }

  @Test("A chosen display is saved for the machine once the connection takes it; a pane's old choice is only a seed")
  func savesTheChosenDisplayForTheMachine() async throws {
    let host = Host()
    host.fixture.host.displays = [FakeHost.display, FakeHost.second]
    let tab = host.fixture.surface(.tab)
    tab.show(seedDisplay: "from an old tab")
    await awaitObserved { tab.snapshot.endpoint != nil }
    #expect(try host.fixture.connection.preferredDisplayId == "from an old tab")
    #expect(host.fixture.preferences.preferredDisplay(machineId: Fixture.machineId) == nil, "a seed is never saved")

    tab.surface.switchDisplay(to: FakeHost.second.id)
    await awaitObserved { (try? host.fixture.connection.preferredDisplayId) == FakeHost.second.id }
    #expect(host.fixture.preferences.preferredDisplay(machineId: Fixture.machineId) == FakeHost.second.id)

    let window = host.fixture.surface(.window)
    window.show(seedDisplay: "another old tab")
    #expect(
      try host.fixture.connection.preferredDisplayId == FakeHost.second.id, "the machine's choice wins over a seed")
  }

  @MainActor
  private final class Host {
    let fixture = Fixture()
    let session = FakeMediaSession(capabilities: [.control, .statistics])
    private var granted = 0

    init() {
      session.resizesDesktop = true
      session.controlChannel.isAvailable = true
      fixture.audioSession = session
    }

    var sent: [ScreenSharingControlMessage] { session.controlChannel.sent.filter { !$0.isHeartbeat } }

    var requests: [UUID] {
      sent.compactMap { if case .request(let id) = $0 { id } else { nil } }
    }

    func controls(_ surface: RecordedSurface) async {
      await awaitObserved { surface.snapshot.hasControl }
      let fake = fixture.fake(for: surface)
      await awaitObserved { fake?.inputActive == true }
    }

    @discardableResult
    func grant() async -> UUID {
      let answered = granted
      await awaitObserved { self.requests.count > answered }
      granted = requests.count
      let lease = UUID()
      if let request = requests.last { session.controlChannel.deliver(.grant(request: request, lease: lease)) }
      return lease
    }
  }
}

extension ScreenSharingControlMessage {
  fileprivate var isHeartbeat: Bool {
    if case .heartbeat = self { true } else { false }
  }
}
