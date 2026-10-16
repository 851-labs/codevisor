import CoreGraphics
import ScreenSharing
import Testing

@testable import ScreenSharingPane

@Suite("Touch and keyboard input")
struct ScreenSharingTouchInputTests {
  let point = ScreenSharingPointer(x: 0.25, y: 0.75)

  private func clickCounts(_ events: [ScreenSharingInputEvent]) -> [UInt8] {
    events.compactMap {
      guard case .button(_, _, true, let clicks, _) = $0 else { return nil }
      return clicks
    }
  }

  @Test("Quick taps in one place become double and triple clicks; a slow or distant tap starts over")
  func multiClick() {
    var input = ScreenSharingPointerInput()
    let here = CGPoint(x: 100, y: 100)
    var counts: [UInt8] = []
    counts += clickCounts(input.tap(at: point, location: here, time: 10))
    counts += clickCounts(input.tap(at: point, location: CGPoint(x: 110, y: 104), time: 10.3))
    counts += clickCounts(input.tap(at: point, location: here, time: 10.6))
    counts += clickCounts(input.tap(at: point, location: here, time: 10.9))
    counts += clickCounts(input.tap(at: point, location: here, time: 11.3))
    counts += clickCounts(input.tap(at: point, location: CGPoint(x: 200, y: 100), time: 11.4))
    #expect(counts == [1, 2, 3, 1, 1, 1])
  }

  @Test("A click moves the pointer there before pressing and releasing the button")
  func clickSequence() {
    var input = ScreenSharingPointerInput()
    #expect(
      input.tap(at: point, location: .zero, time: 0) == [
        .move(point, modifiers: 0),
        .button(point, button: 0, down: true, clicks: 1, modifiers: 0),
        .button(point, button: 0, down: false, clicks: 1, modifiers: 0),
      ])
    #expect(clickCounts(input.secondaryClick(at: point)) == [1])
    #expect(input.secondaryClick(at: point).contains(.button(point, button: 1, down: true, clicks: 1, modifiers: 0)))
  }

  @Test("A drag holds the left button from start to finish and only moves while held")
  func drag() {
    var input = ScreenSharingPointerInput()
    let end = ScreenSharingPointer(x: 0.5, y: 0.5)
    #expect(input.dragMoved(to: end).isEmpty)
    #expect(input.dragBegan(at: point).last == .button(point, button: 0, down: true, clicks: 1, modifiers: 0))
    #expect(input.dragMoved(to: end) == [.move(end, modifiers: 0)])
    #expect(input.dragEnded(at: end).last == .button(end, button: 0, down: false, clicks: 1, modifiers: 0))
    #expect(input.dragEnded(at: end).isEmpty)
  }

  @Test("Fractional scroll deltas accumulate instead of being dropped")
  func scroll() {
    var input = ScreenSharingPointerInput()
    #expect(input.scrolled(at: point, dx: 0, dy: -0.6).isEmpty)
    #expect(input.scrolled(at: point, dx: 0, dy: -0.6) == [.scroll(point, x: 0, y: -1, modifiers: 0)])
  }

  @Test("Typing ASCII presses Mac keys, with Shift for capitals and symbols")
  func typing() {
    #expect(
      ScreenSharingKeyboard.type("a!", modifiers: []) == [
        .key(code: 0, down: true, repeatKey: false, modifiers: 0),
        .key(code: 0, down: false, repeatKey: false, modifiers: 0),
        .key(code: 56, down: true, repeatKey: false, modifiers: 1),
        .key(code: 18, down: true, repeatKey: false, modifiers: 1),
        .key(code: 18, down: false, repeatKey: false, modifiers: 1),
        .key(code: 56, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(ScreenSharingKeyboard.key(for: "Q")?.code == 12)
    #expect(ScreenSharingKeyboard.key(for: "Q")?.shifted == true)
    #expect(ScreenSharingKeyboard.key(for: "\n")?.code == ScreenSharingKey.returnKey.rawValue)
  }

  @Test("Characters without a Mac key are sent as text; with a held modifier they are dropped")
  func unmappedText() {
    #expect(
      ScreenSharingKeyboard.type("é😀x", modifiers: []) == [
        .text("é😀"),
        .key(code: 7, down: true, repeatKey: false, modifiers: 0),
        .key(code: 7, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(ScreenSharingKeyboard.type("é", modifiers: .command).isEmpty)
  }

  @Test("A shortcut holds its modifiers around the key and releases them in reverse")
  func shortcut() {
    let events = ScreenSharingKeyboard.press(code: 8, modifiers: [.command, .shift])
    #expect(
      events == [
        .key(code: 55, down: true, repeatKey: false, modifiers: 8),
        .key(code: 56, down: true, repeatKey: false, modifiers: 9),
        .key(code: 8, down: true, repeatKey: false, modifiers: 9),
        .key(code: 8, down: false, repeatKey: false, modifiers: 9),
        .key(code: 56, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(events.allSatisfy { $0.isValid })
  }

  @Test("Hardware keyboard usages map to the same Mac keys as typed characters")
  func hardwareKeys() {
    #expect(ScreenSharingKeyboard.code(forHIDUsage: 4) == ScreenSharingKeyboard.key(for: "a")?.code)
    #expect(ScreenSharingKeyboard.code(forHIDUsage: 29) == ScreenSharingKeyboard.key(for: "z")?.code)
    #expect(ScreenSharingKeyboard.code(forHIDUsage: 39) == ScreenSharingKeyboard.key(for: "0")?.code)
    #expect(ScreenSharingKeyboard.code(forHIDUsage: 42) == ScreenSharingKey.delete.rawValue)
    #expect(ScreenSharingKeyboard.code(forHIDUsage: 80) == ScreenSharingKey.left.rawValue)
    #expect(ScreenSharingKeyboard.code(forHIDUsage: 225) == nil)
  }
}

@Suite("Dragging near the edge of a zoomed view")
struct ScreenSharingEdgeScrollTests {
  let frame = CGRect(x: 0, y: 0, width: 400, height: 800)

  @Test("Away from the edges the view stays put")
  func middle() {
    #expect(ScreenSharingEdgeScroll.step(finger: CGPoint(x: 200, y: 400), in: frame) == CGVector(dx: 0, dy: 0))
    #expect(ScreenSharingEdgeScroll.step(finger: CGPoint(x: 56, y: 744), in: frame) == CGVector(dx: 0, dy: 0))
  }

  @Test("Nearing an edge scrolls toward it, fastest at the edge itself")
  func edges() {
    let right = ScreenSharingEdgeScroll.step(finger: CGPoint(x: 390, y: 400), in: frame)
    let atRight = ScreenSharingEdgeScroll.step(finger: CGPoint(x: 400, y: 400), in: frame)
    #expect(right.dx > 0 && right.dy == 0)
    #expect(atRight.dx == ScreenSharingEdgeScroll.maximumSpeed && atRight.dx > right.dx)
    let topLeft = ScreenSharingEdgeScroll.step(finger: CGPoint(x: 0, y: 0), in: frame)
    #expect(topLeft.dx == -ScreenSharingEdgeScroll.maximumSpeed && topLeft.dy == -ScreenSharingEdgeScroll.maximumSpeed)
  }
}
