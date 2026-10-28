#if canImport(AppKit)
  import AppKit
  import CodevisorTestSupport
  import SwiftUI
  import Testing
  @testable import Autocomplete

  @Suite("Autocomplete popper presentation")
  @MainActor
  struct PopperPresentationTests {
    @MainActor
    private final class Fixture {
      let window: NSWindow
      let anchor = NSView(frame: NSRect(x: 20, y: 150, width: 80, height: 24))
      let controller = Autocomplete.PopperController()
      let dismissed = TestSignal()
      var dismissals: Int { dismissed.value }

      init() {
        _ = NSApplication.shared
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
          contentRect: NSRect(x: visible.minX + 40, y: visible.maxY - 260, width: 300, height: 200),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
      }

      func present(_ isPresented: Bool = true, content: some View = Color.clear.frame(width: 200, height: 120)) {
        controller.update(
          isPresented: isPresented, content: AnyView(content), environment: EnvironmentValues(), anchor: anchor,
          onDismiss: { self.dismissed.signal() })
      }

      func click(at point: NSPoint) -> NSEvent? {
        let event = NSEvent.mouseEvent(
          with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        return event.flatMap(controller.dismissForClickOutside)
      }

      func close() {
        controller.tearDown()
        window.close()
      }
    }

    @Test("Presenting attaches a child panel directly below the trigger, over a click-through shadow")
    func presents() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      let panel = try #require(fixture.controller.panel)
      let anchor = fixture.window.convertToScreen(fixture.anchor.frame)
      #expect(fixture.window.childWindows?.contains(panel) == true)
      #expect(panel.frame.size == CGSize(width: 200, height: 120))
      #expect(panel.frame.minX == anchor.minX)
      #expect(panel.frame.maxY == anchor.minY - Autocomplete.PopperPlacement.nativeMenuGap)
      #expect(panel.accessibilityRole() == .popover)
      #expect(fixture.window.childWindows == [panel.shadowWindow, panel])
      #expect(panel.shadowWindow.ignoresMouseEvents)
    }

    private struct TallContent: View {
      @Environment(\.autocompleteStyle) private var style
      var body: some View { Color.clear.frame(width: 200, height: min(5000, style.metrics.maximumHeight)) }
    }

    @Test("A menu taller than either side shrinks to the roomier side instead of covering its trigger")
    func shrinksToFit() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      var environment = EnvironmentValues()
      environment.autocompleteStyle.metrics.maximumHeight = 5000
      fixture.controller.update(
        isPresented: true, content: AnyView(TallContent()), environment: environment, anchor: fixture.anchor,
        onDismiss: {})
      let panel = try #require(fixture.controller.panel)
      let anchor = fixture.window.convertToScreen(fixture.anchor.frame)
      let visible = try #require(fixture.window.screen?.visibleFrame)
      #expect(panel.frame.height == Autocomplete.PopperPlacement.availableHeight(anchor: anchor, visibleFrame: visible))
      #expect(!panel.frame.insetBy(dx: 0, dy: 1).intersects(anchor))
    }

    @Test("Clearing the binding fades the panel out without reporting a dismissal back")
    func bindingHides() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      let panel = try #require(fixture.controller.panel)
      fixture.present(false)
      #expect(fixture.controller.panel == nil)
      #expect(fixture.controller.fadingPanel === panel)
      #expect(panel.ignoresMouseEvents)
      #expect(fixture.dismissals == 0)
    }

    @Test("A click outside dismisses and still reaches its target")
    func clickOutside() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      #expect(fixture.click(at: NSPoint(x: 250, y: 20)) != nil)
      #expect(!fixture.controller.consumeClosingTriggerClick())
      #expect(fixture.controller.panel == nil)
      #expect(fixture.dismissals == 1)
    }

    @Test("A click on the trigger dismisses, and that click's own toggle is absorbed so the menu stays closed")
    func clickTrigger() {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      #expect(fixture.click(at: NSPoint(x: 40, y: 160)) != nil)
      #expect(fixture.dismissals == 1)
      #expect(fixture.controller.consumeClosingTriggerClick())
      #expect(!fixture.controller.consumeClosingTriggerClick())
    }

    @Test("A click inside the panel is left to the menu")
    func clickInside() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      let panel = try #require(fixture.controller.panel)
      let inside = fixture.window.convertPoint(fromScreen: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
      #expect(fixture.click(at: inside) != nil)
      #expect(fixture.controller.panel === panel)
      #expect(fixture.dismissals == 0)
    }

    @Test("Escape and losing key status dismiss")
    func escapeAndResignKey() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      try #require(fixture.controller.panel).cancelOperation(nil)
      #expect(fixture.dismissals == 1)
      fixture.present()
      try #require(fixture.controller.panel).resignKey()
      #expect(fixture.dismissals == 2)
      #expect(fixture.controller.panel == nil)
    }

    @Test("Reopening during the fade-out replaces the fading panel with fresh content")
    func reopenWhileFading() throws {
      let fixture = Fixture()
      defer { fixture.close() }
      fixture.present()
      let first = try #require(fixture.controller.panel)
      fixture.present(false)
      fixture.present()
      #expect(fixture.controller.fadingPanel == nil)
      #expect(first.contentView == nil)
      #expect(fixture.controller.panel !== first)
      #expect(fixture.window.childWindows?.contains(first) == false)
    }

    @Test("Removing the trigger removes the panel at once and reports the dismissal")
    func tearDown() async throws {
      let fixture = Fixture()
      defer { fixture.window.close() }
      fixture.present()
      let panel = try #require(fixture.controller.panel)
      fixture.controller.tearDown()
      #expect(fixture.window.childWindows?.contains(panel) == false)
      #expect(!panel.isVisible)
      #expect(fixture.dismissals == 0)
      await fixture.dismissed.wait(for: 1)
    }

    @Test("Menu content inherits the trigger's environment and Escape clears the binding")
    func menuEnvironment() throws {
      let isPresented = SelectionStore(true)
      let fixture = Fixture()
      defer { fixture.close() }
      let host = NSHostingView(
        rootView: Autocomplete.Menu(isPresented: isPresented.binding) {
          Autocomplete.Action("Match") {}
        } label: {
          Text("Open")
        }
        .autocompleteSearchLabel("Search fixtures")
        .environment(\.locale, Locale(identifier: "en_US_POSIX")))
      host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
      fixture.window.contentView = host
      host.layoutSubtreeIfNeeded()
      let panel = try #require(fixture.window.childWindows?.lazy.compactMap { $0 as? Autocomplete.PopperPanel }.first)
      panel.host.layoutSubtreeIfNeeded()
      let field = try #require(searchField(in: panel.host))
      #expect(field.accessibilityLabel() == "Search fixtures")
      let coordinator = try #require(field.delegate as? Autocomplete.InputField.Coordinator)
      #expect(
        coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
      #expect(!isPresented.value)
    }

    private func searchField(in view: NSView) -> NSSearchField? {
      if let field = view as? NSSearchField { return field }
      return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
  }
#endif
