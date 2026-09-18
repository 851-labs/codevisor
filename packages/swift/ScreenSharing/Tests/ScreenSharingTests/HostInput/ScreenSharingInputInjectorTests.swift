import AppKit
import Testing

@testable import ScreenSharing

/// The Quartz events the host would post for each remote event. The injector's
/// delivery closure is replaced throughout, so nothing here moves the cursor or
/// types on the machine running the suite — the events are inspected and
/// dropped.
@MainActor
struct ScreenSharingInputInjectorTests {
  private static let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  @Test func aPointerMapsOntoTheDisplayAndStaysInsideItsLastPixel() {
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: { _ in })
    #expect(injector.location(.init(x: 0, y: 0)) == CGPoint(x: 0, y: 0))
    #expect(injector.location(.init(x: 0.5, y: 0.5)) == CGPoint(x: 960, y: 540))
    // A pointer at the far edge must not land on the next display over.
    #expect(injector.location(.init(x: 1, y: 1)) == CGPoint(x: 1919.999, y: 1079.999))
  }

  @Test func aDisplayLeftOfTheMainOneKeepsItsNegativeOrigin() {
    let bounds = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
    let injector = ScreenSharingInputInjector(displayBounds: bounds, deliver: { _ in })
    #expect(injector.location(.init(x: 0, y: 0)) == CGPoint(x: -1920, y: -100))
    #expect(injector.location(.init(x: 0.5, y: 0.5)) == CGPoint(x: -960, y: 440))
  }

  @Test func aClickCarriesItsButtonLocationAndClickCount() throws {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    try #require(injector.isAvailable)
    injector.post(.button(.init(x: 0.5, y: 0.25), button: 0, down: true, clicks: 2, modifiers: 0))
    injector.post(.button(.init(x: 0.5, y: 0.25), button: 0, down: false, clicks: 2, modifiers: 0))
    injector.post(.button(.init(x: 0, y: 0), button: 1, down: true, clicks: 1, modifiers: 0))
    injector.post(.button(.init(x: 0, y: 0), button: 1, down: false, clicks: 1, modifiers: 0))
    injector.post(.button(.init(x: 1, y: 1), button: 2, down: true, clicks: 1, modifiers: 0))
    injector.post(.button(.init(x: 1, y: 1), button: 2, down: false, clicks: 1, modifiers: 0))
    #expect(
      recorder.types == [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
      ])
    #expect(recorder.events.map { $0.getIntegerValueField(.mouseEventButtonNumber) } == [0, 0, 1, 1, 2, 2])
    #expect(recorder.events.map { $0.getIntegerValueField(.mouseEventClickState) } == [2, 2, 1, 1, 1, 1])
    #expect(try #require(recorder.events.first).location == CGPoint(x: 960, y: 270))
  }

  @Test func motionBecomesADragForTheLowestHeldButtonAndAPlainMoveOnceTheyAreReleased() throws {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    let point = ScreenSharingPointer(x: 0.5, y: 0.5)
    injector.post(.move(point, modifiers: 0))
    injector.post(.button(point, button: 2, down: true, clicks: 1, modifiers: 0))
    injector.post(.move(point, modifiers: 0))
    injector.post(.button(point, button: 1, down: true, clicks: 1, modifiers: 0))
    injector.post(.move(point, modifiers: 0))
    injector.post(.button(point, button: 0, down: true, clicks: 1, modifiers: 0))
    injector.post(.move(point, modifiers: 0))
    injector.post(.button(point, button: 0, down: false, clicks: 1, modifiers: 0))
    injector.post(.button(point, button: 1, down: false, clicks: 1, modifiers: 0))
    injector.post(.button(point, button: 2, down: false, clicks: 1, modifiers: 0))
    injector.post(.move(point, modifiers: 0))
    #expect(
      recorder.types.filter { [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains($0) }
        == [.mouseMoved, .otherMouseDragged, .rightMouseDragged, .leftMouseDragged, .mouseMoved])
  }

  @Test func scrollingCarriesPixelDeltasOnBothAxesAtThePointer() throws {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    injector.post(.scroll(.init(x: 0.25, y: 0.75), x: -7, y: 13, modifiers: 0))
    let event = try #require(recorder.events.first)
    #expect(event.type == .scrollWheel)
    #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 13)
    #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -7)
    #expect(event.location == CGPoint(x: 480, y: 810))
  }

  @Test func keysCarryTheirCodeAndWhetherTheyAreAutorepeats() throws {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    injector.post(.key(code: 12, down: true, repeatKey: false, modifiers: 0))
    injector.post(.key(code: 12, down: true, repeatKey: true, modifiers: 0))
    injector.post(.key(code: 12, down: false, repeatKey: false, modifiers: 0))
    #expect(recorder.types == [.keyDown, .keyDown, .keyUp])
    #expect(recorder.events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 12 })
    #expect(recorder.events.map { $0.getIntegerValueField(.keyboardEventAutorepeat) } == [0, 1, 0])
  }

  @Test func pastedTextIsOneKeystrokePairCarryingTheWholeString() throws {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    injector.post(.text("héllo 👋"))
    #expect(recorder.types == [.keyDown, .keyUp])
    for event in recorder.events {
      #expect(event.getIntegerValueField(.keyboardEventKeycode) == 0, "no physical key stands for the string")
      var length = 0
      var buffer = [UniChar](repeating: 0, count: 32)
      event.keyboardGetUnicodeString(maxStringLength: 32, actualStringLength: &length, unicodeString: &buffer)
      #expect(String(utf16CodeUnits: buffer, count: length) == "héllo 👋")
    }
  }

  @Test(arguments: modifierBits)
  func everyModifierBitMapsOntoItsQuartzFlag(modifiers: UInt8, expected: CGEventFlags) throws {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    injector.post(.key(code: 12, down: true, repeatKey: false, modifiers: modifiers))
    let known: CGEventFlags = [
      .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn,
    ]
    #expect(try #require(recorder.events.first).flags.intersection(known) == expected)
  }

  @Test func everyInjectedEventIsTaggedSoTheViewerIgnoresItsOwnEcho() {
    let recorder = InjectionRecorder()
    let injector = ScreenSharingInputInjector(displayBounds: Self.display, deliver: recorder.deliver)
    let point = ScreenSharingPointer(x: 0.5, y: 0.5)
    injector.post(.move(point, modifiers: 0))
    injector.post(.button(point, button: 0, down: true, clicks: 1, modifiers: 0))
    injector.post(.scroll(point, x: 1, y: 1, modifiers: 0))
    injector.post(.key(code: 12, down: true, repeatKey: false, modifiers: 0))
    injector.post(.text("x"))
    #expect(recorder.events.count == 6)
    #expect(
      recorder.events.allSatisfy {
        $0.getIntegerValueField(.eventSourceUserData) == ScreenSharingInputInjector.eventTag
      })
  }
}

private let modifierBits: [(UInt8, CGEventFlags)] = [
  (0, []),
  (1, .maskShift),
  (2, .maskControl),
  (4, .maskAlternate),
  (8, .maskCommand),
  (16, .maskAlphaShift),
  (32, .maskSecondaryFn),
  (63, [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn]),
]

@MainActor
private final class InjectionRecorder {
  private(set) var events: [CGEvent] = []
  var types: [CGEventType] { events.map(\.type) }
  lazy var deliver: (CGEvent) -> Void = { [unowned self] in events.append($0) }
}
