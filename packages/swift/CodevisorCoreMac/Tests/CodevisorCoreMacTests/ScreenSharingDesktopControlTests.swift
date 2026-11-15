import CodevisorCore
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
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

  @Test("Hiding the surface with control gives it to a surface still on screen, or back to the host if none is")
  func passesControlOnWhenItsSurfaceHides() async throws {
    let host = Host()
    let (window, tab) = (host.fixture.surface(.window), host.fixture.surface(.tab))
    window.show()
    let lease = await host.grant()
    await awaitObserved { window.snapshot.hasControl }
    tab.show()

    window.hide()
    #expect(tab.snapshot.hasControl && host.sent.count == 1, "the tab takes over locally")

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

    tab.surface.setMode(.control)
    await awaitObserved { host.requests.count == 2 }
    #expect(tab.snapshot.control != nil && window.snapshot.control == nil, "the surface that asked gets it")
    #expect(!host.fixture.preferences.viewOnly(machineId: Fixture.machineId))
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

  @Test("A display is saved for the machine only once the connection shares it")
  func savesTheDisplayOnceShared() async throws {
    let host = Host()
    let tab = host.fixture.surface(.tab)
    tab.show()
    await awaitObserved { tab.snapshot.endpoint != nil }
    let shared = try #require(tab.snapshot.displayId)

    tab.surface.switchDisplay(to: "another")
    #expect(host.fixture.preferences.preferredDisplay(machineId: Fixture.machineId) == nil)

    tab.surface.switchDisplay(to: shared)
    #expect(host.fixture.preferences.preferredDisplay(machineId: Fixture.machineId) == shared)
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
