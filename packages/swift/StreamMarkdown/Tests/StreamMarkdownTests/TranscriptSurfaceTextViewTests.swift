import AppKit
@testable import StreamMarkdown
import Testing

/// A stand-in for the virtualized transcript: it owns focus and, like the
/// real coordinator, drops its selection the moment focus leaves it.
@MainActor
private final class SelectionHost: NSView, TranscriptSelectionCoordinating {
  var hasSelection = true
  var clearCount = 0
  var menuEvents: [NSEvent] = []

  override var acceptsFirstResponder: Bool { true }

  override func resignFirstResponder() -> Bool {
    guard super.resignFirstResponder() else { return false }
    clearTranscriptSelection()
    return true
  }

  func beginTranscriptSelection(with _: NSEvent, in _: NSTextView) -> Bool { false }
  func continueTranscriptSelection(with _: NSEvent) {}
  func endTranscriptSelection(with _: NSEvent) {}

  func clearTranscriptSelection() {
    hasSelection = false
    clearCount += 1
  }

  func transcriptSelectionMenu(for _: NSTextView, with event: NSEvent) -> NSMenu? {
    menuEvents.append(event)
    guard hasSelection else { return nil }
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
    return menu
  }
}

/// Records menus instead of showing them. A real pop-up — the coordinator's
/// or `NSTextView`'s own — runs a tracking loop that blocks the test process
/// until someone dismisses it on screen.
@MainActor
private final class RecordingSurface: TranscriptSurfaceTextView {
  var presentedMenus: [NSMenu] = []
  var nativeMenuRequests = 0

  override func popUpTranscriptSelectionMenu(_ menu: NSMenu, with _: NSEvent) {
    presentedMenus.append(menu)
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    nativeMenuRequests += 1
    return nil
  }
}

@MainActor
@Suite("Transcript surface secondary click")
struct TranscriptSurfaceTextViewTests {
  private struct Fixture {
    let window: NSWindow
    let host: SelectionHost
    let surface: RecordingSurface

    func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(
        with: type,
        location: NSPoint(x: 40, y: 150),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      )!
    }
  }

  private func makeFixture() -> Fixture {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let host = SelectionHost(frame: window.contentView!.bounds)
    window.contentView!.addSubview(host)
    let surface = RecordingSurface(frame: host.bounds)
    surface.isEditable = false
    surface.isSelectable = true
    surface.string = "All seven Swift runs executed the same tests"
    host.addSubview(surface)
    window.makeFirstResponder(host)
    return Fixture(window: window, host: host, surface: surface)
  }

  @Test("A right click with a transcript selection shows its menu and keeps the selection")
  func rightClickKeepsTranscriptSelection() {
    let fixture = makeFixture()
    let nativeSelection = fixture.surface.selectedRange()
    let click = fixture.click(.rightMouseDown)

    fixture.surface.rightMouseDown(with: click)

    #expect(fixture.surface.presentedMenus.count == 1)
    #expect(fixture.host.menuEvents.map(\.locationInWindow) == [click.locationInWindow])
    #expect(fixture.host.hasSelection)
    #expect(fixture.host.clearCount == 0)
    #expect(fixture.window.firstResponder === fixture.host)
    #expect(fixture.surface.selectedRange() == nativeSelection)
  }

  @Test("A control click behaves like a right click")
  func controlClickKeepsTranscriptSelection() {
    let fixture = makeFixture()

    fixture.surface.mouseDown(with: fixture.click(.leftMouseDown, modifiers: .control))

    #expect(fixture.surface.presentedMenus.count == 1)
    #expect(fixture.host.hasSelection)
    #expect(fixture.window.firstResponder === fixture.host)
  }

  @Test("Without a transcript selection the surface keeps its native menu")
  func rightClickWithoutSelectionIsNative() {
    let fixture = makeFixture()
    fixture.host.hasSelection = false
    fixture.host.clearCount = 0

    fixture.surface.rightMouseDown(with: fixture.click(.rightMouseDown))

    #expect(fixture.surface.presentedMenus.isEmpty)
    #expect(fixture.surface.nativeMenuRequests == 1)
    #expect(fixture.window.firstResponder === fixture.surface)
  }

  @Test("A right click on a link stays with the native link menu")
  func rightClickOnLinkIsNative() {
    let fixture = makeFixture()
    fixture.surface.textStorage?.addAttribute(
      .link,
      value: URL(string: "https://example.com")!,
      range: NSRange(location: 0, length: fixture.surface.string.utf16.count)
    )

    fixture.surface.rightMouseDown(with: fixture.click(.rightMouseDown))

    #expect(fixture.surface.presentedMenus.isEmpty)
    #expect(fixture.surface.nativeMenuRequests == 1)
    #expect(fixture.host.menuEvents.isEmpty)
  }
}
