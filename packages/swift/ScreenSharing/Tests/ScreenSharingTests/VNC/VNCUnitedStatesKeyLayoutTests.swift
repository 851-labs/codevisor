import Testing

@testable import ScreenSharing

@Suite("The fixed US key layout for viewers that can't read a keyboard layout")
struct VNCUnitedStatesKeyLayoutTests {
  private let keys = VNCKeyTranslator(layout: VNCUnitedStatesKeyLayout.layout)

  @Test(
    "A key gives its plain character, and its shifted one with Shift",
    arguments: [
      (UInt16(0), "a", "A"), (18, "1", "!"), (27, "-", "_"), (39, "'", "\""), (42, "\\", "|"), (50, "`", "~"),
      (49, " ", " "),
    ] as [(UInt16, Unicode.Scalar, Unicode.Scalar)])
  func plainAndShifted(code: UInt16, plain: Unicode.Scalar, shifted: Unicode.Scalar) {
    #expect(keys.keysym(code: code, modifiers: 0) == plain.value)
    #expect(keys.keysym(code: code, modifiers: 1) == shifted.value)
  }

  @Test("Option, Control and Command leave the character alone, so Alt and Control shortcuts name the plain key")
  func otherModifiersKeepTheCharacter() {
    for modifiers in [UInt8(2), 4, 8, 14] { #expect(keys.keysym(code: 8, modifiers: modifiers) == 0x63) }
    #expect(keys.keysym(code: 8, modifiers: 4 | 1) == 0x43)
  }

  @Test("A key the layout doesn't have is dropped")
  func unknownKey() {
    #expect(keys.keysym(code: 10, modifiers: 0) == nil)
    #expect(keys.keysym(code: 200, modifiers: 1) == nil)
  }
}
