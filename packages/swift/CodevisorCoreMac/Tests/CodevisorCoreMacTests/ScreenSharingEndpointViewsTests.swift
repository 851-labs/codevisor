import AppKit
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("One connection drawn by several panes")
struct ScreenSharingEndpointViewsTests {
  private let tab = UUID()
  private let window = UUID()

  @Test("Every pane gets its own view on its own copy of the frames, and keeps it")
  func givesEveryPaneItsOwnView() throws {
    let fixture = Fixture()
    let tabView = try #require(fixture.endpoint.view(for: tab))
    let windowView = try #require(fixture.endpoint.view(for: window))

    #expect(tabView !== windowView)
    #expect(fixture.endpoint.view(for: tab) === tabView, "asking again returns the pane's view, not a new one")
    #expect(fixture.made.count == 2)
    #expect(fixture.made[0].frames === fixture.session.frames.tap(tab))
    #expect(fixture.made[1].frames === fixture.session.frames.tap(window))
    #expect(fixture.made[0].frames !== fixture.made[1].frames)
    #expect(fixture.made[0].metrics !== fixture.made[1].metrics, "each view counts its own presented frames")
    #expect(fixture.made.allSatisfy { $0.metrics.timeline === fixture.session.metrics.timeline })
  }

  @Test("Only the pane with the keyboard and mouse sends input and decides the host's size")
  func takesInputAndSizeFromOnePane() throws {
    let fixture = Fixture()
    let surfaces = try fixture.show(tab, window)
    fixture.endpoint.setDynamicResolution(true)
    fixture.endpoint.moveInput(to: tab)
    fixture.endpoint.sizeDesktop(with: tab)
    let lease = UUID()
    #expect(fixture.endpoint.beginInput(lease: lease) == nil)

    surfaces[1].onSizeChanged?(CGSize(width: 800, height: 600), 1)
    surfaces[1].onInput?(.text("ignored"))
    surfaces[0].onSizeChanged?(CGSize(width: 640, height: 400), 1)
    surfaces[0].onInput?(.text("typed"))

    #expect(fixture.session.desktopSizeRequests == [[640, 400]])
    #expect(fixture.session.controlChannel.sent == [.input(lease: lease, sequence: 1, event: .text("typed"))])
    #expect(surfaces[0].inputActive && !surfaces[1].inputActive)
  }

  @Test("Moving the keyboard and mouse to another pane keeps the lease: nothing is sent, capture just changes views")
  func movesInputToAnotherPane() throws {
    let fixture = Fixture()
    let surfaces = try fixture.show(tab, window)
    fixture.endpoint.setDynamicResolution(true)
    surfaces[0].onSizeChanged?(CGSize(width: 640, height: 400), 1)
    surfaces[1].onSizeChanged?(CGSize(width: 800, height: 600), 1)
    fixture.endpoint.moveInput(to: tab)
    fixture.endpoint.sizeDesktop(with: tab)
    let lease = UUID()
    _ = fixture.endpoint.beginInput(lease: lease)

    surfaces[0].heldKey = 56
    fixture.endpoint.moveInput(to: window)
    fixture.endpoint.sizeDesktop(with: window)
    surfaces[0].onInput?(.text("ignored"))
    surfaces[1].onInput?(.text("typed"))

    let released = ScreenSharingInputEvent.key(code: 56, down: false, repeatKey: false, modifiers: 0)
    #expect(
      fixture.session.controlChannel.sent == [
        .input(lease: lease, sequence: 1, event: released), .input(lease: lease, sequence: 2, event: .text("typed")),
      ], "a key held on the old pane is released on the host before the new pane types")
    #expect(!surfaces[0].inputActive && surfaces[1].inputActive, "the old pane stops capturing; it keeps its view")
    #expect(fixture.endpoint.view(for: tab) === surfaces[0].view && !surfaces[0].stopped)
    #expect(fixture.session.desktopSizeRequests == [[640, 400], [800, 600]])
  }

  @Test("The view that sizes the host desktop can be another one than the view with the keyboard and mouse")
  func sizesTheDesktopWithAnyPane() throws {
    let fixture = Fixture()
    let surfaces = try fixture.show(tab, window)
    fixture.endpoint.setDynamicResolution(true)
    surfaces[0].onSizeChanged?(CGSize(width: 640, height: 400), 1)
    surfaces[1].onSizeChanged?(CGSize(width: 800, height: 600), 1)

    fixture.endpoint.sizeDesktop(with: window)
    #expect(fixture.session.desktopSizeRequests == [[800, 600]])
    #expect(fixture.endpoint.size(of: tab) == CGSize(width: 640, height: 400))

    fixture.endpoint.sizeDesktop(with: nil)
    surfaces[1].onSizeChanged?(CGSize(width: 900, height: 600), 1)
    #expect(fixture.session.desktopSizeRequests == [[800, 600]], "with nobody sizing it, the desktop is left alone")
  }

  @Test("A pane that goes away stops its view, and a focus change names the pane it happened in")
  func dropsAClosedPanesViewAndRoutesFocus() throws {
    let fixture = Fixture()
    let surfaces = try fixture.show(tab, window)
    var focused: [UUID] = []
    fixture.endpoint.onViewFocusChanged = { id, isFocused in if isFocused { focused.append(id) } }
    surfaces[1].onFocusChanged?(true)
    #expect(focused == [window])

    fixture.endpoint.removeView(for: tab)

    #expect(surfaces[0].stopped && !surfaces[1].stopped)
    #expect(fixture.session.frames.tap(tab) !== fixture.made[0].frames, "its copy of the frames is released")
    let fresh = try #require(fixture.endpoint.view(for: tab))
    #expect(fresh !== surfaces[0].view)
  }

  @MainActor
  private final class Fixture {
    let session = FakeMediaSession(capabilities: [.control, .statistics])
    private(set) var made: [(frames: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, surface: FakeSurface)] =
      []
    private(set) lazy var endpoint = ScreenSharingViewerEndpoint(session: session) { [unowned self] frames, metrics in
      let surface = FakeSurface()
      self.made.append((frames, metrics, surface))
      return surface
    }

    init() {
      session.resizesDesktop = true
      session.controlChannel.isAvailable = true
    }

    isolated deinit {
      endpoint.close()
    }

    func show(_ panes: UUID...) throws -> [FakeSurface] {
      for pane in panes { _ = try #require(endpoint.view(for: pane)) }
      return made.map(\.surface)
    }
  }
}
