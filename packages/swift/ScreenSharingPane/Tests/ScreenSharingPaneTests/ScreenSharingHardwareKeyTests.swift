import ScreenSharing
import Testing

@testable import ScreenSharingPane

@Suite("A hardware keyboard's keys")
struct ScreenSharingHardwareKeyTests {
  private func pressed(_ events: [ScreenSharingInputEvent]?) -> [UInt16] {
    (events ?? []).compactMap {
      guard case .key(let code, true, _, _) = $0 else { return nil }

      return code
    }
  }

  @Test("For a Mac, a key is its position, whatever the keyboard's layout calls it")
  func positionForAMac() {
    let germanZ = ScreenSharingHardwareKey(usage: 28, characters: "z", unmodifiedCharacters: "z")
    #expect(pressed(germanZ.events(asCharacters: false)) == [16])
  }

  @Test("For a desktop that takes characters, a letter is the one the keyboard's layout gives")
  func characterForLinux() {
    let germanZ = ScreenSharingHardwareKey(usage: 28, characters: "z", unmodifiedCharacters: "z")
    #expect(pressed(germanZ.events(asCharacters: true)) == [6])
  }

  @Test("A character the US table lacks is sent as text, shifted or not")
  func charactersOutsideTheTable() {
    let plain = ScreenSharingHardwareKey(usage: 51, characters: "ö", unmodifiedCharacters: "ö")
    let shifted = ScreenSharingHardwareKey(
      usage: 51, characters: "Ö", unmodifiedCharacters: "ö", modifiers: .shift)
    #expect(plain.events(asCharacters: true) == [.text("ö")])
    #expect(shifted.events(asCharacters: true) == [.text("Ö")])
  }

  @Test("Shift or Caps Lock sends the capital the keyboard reports, holding Shift for it once")
  func capitals() {
    let shifted = ScreenSharingHardwareKey(usage: 4, characters: "A", unmodifiedCharacters: "a", modifiers: .shift)
    let capsLocked = ScreenSharingHardwareKey(usage: 4, characters: "A", unmodifiedCharacters: "a")
    #expect(pressed(shifted.events(asCharacters: true)) == [56, 0])
    #expect(pressed(capsLocked.events(asCharacters: true)) == [56, 0])
  }

  @Test("With Command or Option held, the key's own letter goes with the modifier, not the symbol Option composes")
  func chords() {
    let undo = ScreenSharingHardwareKey(usage: 28, characters: "z", unmodifiedCharacters: "z", modifiers: .command)
    let altA = ScreenSharingHardwareKey(usage: 4, characters: "å", unmodifiedCharacters: "a", modifiers: .option)
    #expect(pressed(undo.events(asCharacters: true)) == [55, 6])
    #expect(pressed(altA.events(asCharacters: true)) == [58, 0])
  }

  @Test("Keys without a character, and dead keys, still go by position")
  func positionFallback() {
    let left = ScreenSharingHardwareKey(usage: 80, characters: "UIKeyInputLeftArrow", unmodifiedCharacters: "")
    let deadKey = ScreenSharingHardwareKey(usage: 46)
    #expect(pressed(left.events(asCharacters: true)) == [123])
    #expect(pressed(deadKey.events(asCharacters: true)) == [24])
  }

  @Test("A key Codevisor has no position for is left to the system")
  func unknownKey() {
    #expect(ScreenSharingHardwareKey(usage: 225).events(asCharacters: false) == nil)
    #expect(ScreenSharingHardwareKey(usage: 225).events(asCharacters: true) == nil)
  }
}
