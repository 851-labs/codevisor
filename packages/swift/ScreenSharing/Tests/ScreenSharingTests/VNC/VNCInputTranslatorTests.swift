import ScreenSharing
import Foundation
import Testing
@testable import ScreenSharing

@MainActor
struct VNCInputTranslatorTests {
  /// Code 0 is a letter; Shift (bit 1 of the Carbon state) uppercases it.
  let translator = VNCInputTranslator(
    width: 200, height: 100,
    keys: VNCKeyTranslator(layout: { code, modifiers in code == 0 ? (modifiers & 2 != 0 ? "A" : "a") : nil }))

  @Test func pointerMovesButtonsAndWheelClicks() {
    let centre = ScreenSharingPointer(x: 0.5, y: 0.5), corner = ScreenSharingPointer(x: 1, y: 1)
    #expect(translator.translate(.move(centre, modifiers: 0)) == [.pointerEvent(buttons: 0, x: 100, y: 50)])
    #expect(
      translator.translate(.button(corner, button: 1, down: true, clicks: 1, modifiers: 0))
        == [.pointerEvent(buttons: 4, x: 199, y: 99)])
    #expect(
      translator.translate(.button(corner, button: 0, down: true, clicks: 2, modifiers: 0))
        == [.pointerEvent(buttons: 5, x: 199, y: 99)])
    #expect(
      translator.translate(.button(corner, button: 1, down: false, clicks: 1, modifiers: 0))
        == [.pointerEvent(buttons: 1, x: 199, y: 99)])
    // 45 px up = two wheel-up clicks with the left button still held; 5 px left = one wheel-left click.
    #expect(
      translator.translate(.scroll(corner, x: 0, y: 45, modifiers: 0)) == [
        .pointerEvent(buttons: 9, x: 199, y: 99), .pointerEvent(buttons: 1, x: 199, y: 99),
        .pointerEvent(buttons: 9, x: 199, y: 99), .pointerEvent(buttons: 1, x: 199, y: 99),
      ])
    #expect(
      translator.translate(.scroll(corner, x: -5, y: 0, modifiers: 0))
        == [.pointerEvent(buttons: 65, x: 199, y: 99), .pointerEvent(buttons: 1, x: 199, y: 99)])
    #expect(translator.release() == [.pointerEvent(buttons: 0, x: 199, y: 99)])
    #expect(translator.release() == [])
  }

  @Test func keysGoThroughTheLayoutWithoutControlOrCommand() {
    #expect(
      translator.translate(.key(code: 0, down: true, repeatKey: false, modifiers: 0)) == [
        .keyEvent(keysym: 0x61, down: true)
      ])
    #expect(
      translator.translate(.key(code: 0, down: false, repeatKey: false, modifiers: 1)) == [
        .keyEvent(keysym: 0x41, down: false)
      ])
    #expect(
      translator.translate(.key(code: 0, down: true, repeatKey: false, modifiers: 8 | 2)) == [
        .keyEvent(keysym: 0x61, down: true)
      ])
    #expect(
      translator.translate(.key(code: 36, down: true, repeatKey: false, modifiers: 0)) == [
        .keyEvent(keysym: RFBKeysym.return, down: true)
      ])
    #expect(
      translator.translate(.key(code: 55, down: true, repeatKey: false, modifiers: 8)) == [
        .keyEvent(keysym: RFBKeysym.controlRight, down: true)
      ])
    #expect(translator.translate(.key(code: 63, down: true, repeatKey: false, modifiers: 32)) == [])
    // Unknown to the layout.
    #expect(translator.translate(.key(code: 1, down: true, repeatKey: false, modifiers: 0)) == [])
    #expect(
      translator.translate(.text("hé")) == [
        .keyEvent(keysym: 0x68, down: true), .keyEvent(keysym: 0x68, down: false),
        .keyEvent(keysym: 0xe9, down: true), .keyEvent(keysym: 0xe9, down: false),
      ])
  }

  @Test func theCurrentKeyboardLayoutProducesLatinLettersAndSpace() {
    let keys = VNCKeyTranslator()
    let lower = try? #require(keys.keysym(code: 0, modifiers: 0))
    #expect(lower.map { (0x61...0x7a).contains($0) } == true)
    #expect(keys.keysym(code: 0, modifiers: 1) == lower.map { $0 - 32 })
    #expect(keys.keysym(code: 49, modifiers: 0) == 0x20)
    #expect(keys.keysym(code: 126, modifiers: 0) == RFBKeysym.up)
  }
}
