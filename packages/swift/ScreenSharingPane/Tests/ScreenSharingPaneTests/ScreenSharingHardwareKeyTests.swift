import ScreenSharing
import Testing

@testable import ScreenSharingPane

@Suite("A hardware keyboard's keys")
struct ScreenSharingHardwareKeyTests {
  typealias Key = ScreenSharingHardwareKey

  private func pressed(_ events: [ScreenSharingInputEvent]?) -> [UInt16] {
    (events ?? []).compactMap {
      guard case .key(let code, true, _, _) = $0 else { return nil }

      return code
    }
  }

  @Test("For a Mac, a key is its position, whatever the keyboard's layout calls it")
  func positionForAMac() {
    let germanZ = Key(usage: 28, characters: "z", unmodifiedCharacters: "z")
    #expect(pressed(germanZ.events(asCharacters: false)) == [16])
    #expect(pressed(germanZ.events(asCharacters: false, onScreen: .shift)) == [56, 16])
  }

  @Test("For a desktop that takes characters, a letter is the one the keyboard's layout gives")
  func characterForLinux() {
    let germanZ = Key(usage: 28, characters: "z", unmodifiedCharacters: "z")
    #expect(pressed(germanZ.events(asCharacters: true)) == [6])
  }

  @Test("A character the US table lacks is sent as text, shifted or not")
  func charactersOutsideTheTable() {
    let plain = Key(usage: 51, characters: "ö", unmodifiedCharacters: "ö")
    let shifted = Key(usage: 51, characters: "Ö", unmodifiedCharacters: "ö", modifiers: .shift)
    #expect(plain.events(asCharacters: true) == [.text("ö")])
    #expect(shifted.events(asCharacters: true) == [.text("Ö")])
  }

  @Test(
    "An invisible character a layout types, like Persian's zero-width non-joiner, is typed, not replaced by a US key")
  func invisibleCharacters() {
    let nonJoiner = Key(usage: 5, characters: "\u{200c}", unmodifiedCharacters: "\u{630}", modifiers: .shift)
    #expect(nonJoiner.events(asCharacters: true) == [.text("\u{200c}")])
  }

  @Test("Shift or Caps Lock on the keyboard sends the capital iOS reports, holding Shift for it once")
  func capitals() {
    let shifted = Key(usage: 4, characters: "A", unmodifiedCharacters: "a", modifiers: .shift)
    let capsLocked = Key(usage: 4, characters: "A", unmodifiedCharacters: "a")
    #expect(pressed(shifted.events(asCharacters: true)) == [56, 0])
    #expect(pressed(capsLocked.events(asCharacters: true)) == [56, 0])
  }

  @Test("Shift tapped in the on-screen bar capitalises a hardware key, which iOS reported without it")
  func onScreenShift() {
    let a = Key(usage: 4, characters: "a", unmodifiedCharacters: "a")
    let umlaut = Key(usage: 51, characters: "ö", unmodifiedCharacters: "ö")
    #expect(pressed(a.events(asCharacters: true, onScreen: .shift)) == [56, 0])
    #expect(umlaut.events(asCharacters: true, onScreen: .shift) == [.text("Ö")])
  }

  @Test(
    "Shift tapped on screen can't know a layout's shifted symbol, so a non-letter is typed as it is, with Shift held")
  func onScreenShiftOnANonLetter() {
    let germanTwo = Key(usage: 31, characters: "2", unmodifiedCharacters: "2")
    let sharpS = Key(usage: 45, characters: "ß", unmodifiedCharacters: "ß")
    let shiftDown = ScreenSharingInputEvent.key(code: 56, down: true, repeatKey: false, modifiers: 1)
    let shiftUp = ScreenSharingInputEvent.key(code: 56, down: false, repeatKey: false, modifiers: 0)
    #expect(germanTwo.events(asCharacters: true, onScreen: .shift) == [shiftDown, .text("2"), shiftUp])
    let micro = Key(usage: 16, characters: "µ", unmodifiedCharacters: "m", modifiers: .option)
    #expect(sharpS.events(asCharacters: true, onScreen: .shift) == [shiftDown, .text("ß"), shiftUp])
    #expect(micro.events(asCharacters: true, onScreen: .shift) == [shiftDown, .text("µ"), shiftUp])
  }

  @Test("Shift tapped on screen adds nothing to a letter Caps Lock or the keyboard's Shift already capitalised")
  func onScreenShiftOnACapital() {
    let capsLocked = Key(usage: 4, characters: "A", unmodifiedCharacters: "a")
    let umlaut = Key(usage: 51, characters: "Ö", unmodifiedCharacters: "ö", modifiers: .shift)
    #expect(pressed(capsLocked.events(asCharacters: true, onScreen: .shift)) == [56, 0])
    #expect(umlaut.events(asCharacters: true, onScreen: .shift) == [.text("Ö")])
  }

  @Test("A character the layout makes with Option is typed as that character, not as Alt and the key's letter")
  func optionComposedCharacters() {
    let germanAt = Key(usage: 15, characters: "@", unmodifiedCharacters: "l", modifiers: .option)
    let germanBackslash = Key(usage: 36, characters: "\\", unmodifiedCharacters: "7", modifiers: [.option, .shift])
    let euro = Key(usage: 8, characters: "€", unmodifiedCharacters: "e", modifiers: .option)
    #expect(pressed(germanAt.events(asCharacters: true)) == [56, 19])
    #expect(pressed(germanBackslash.events(asCharacters: true)) == [42])
    #expect(euro.events(asCharacters: true) == [.text("€")])
  }

  @Test("Option that composes nothing, or comes from the on-screen bar, is Alt with the key's own letter")
  func optionAsAlt() {
    let plain = Key(usage: 15, characters: "l", unmodifiedCharacters: "l", modifiers: .option)
    let shifted = Key(usage: 15, characters: "L", unmodifiedCharacters: "l", modifiers: [.option, .shift])
    let onScreen = Key(usage: 15, characters: "l", unmodifiedCharacters: "l")
    #expect(pressed(plain.events(asCharacters: true)) == [58, 37])
    #expect(pressed(shifted.events(asCharacters: true)) == [56, 58, 37])
    #expect(pressed(onScreen.events(asCharacters: true, onScreen: .option)) == [58, 37])
  }

  @Test("With Command or Control held, the key's own letter goes with the modifiers, whatever Option composed")
  func chords() {
    let undo = Key(usage: 28, characters: "z", unmodifiedCharacters: "z", modifiers: .command)
    let withOption = Key(usage: 15, characters: "@", unmodifiedCharacters: "l", modifiers: [.command, .option])
    let onScreenControl = Key(usage: 6, characters: "c", unmodifiedCharacters: "c")
    #expect(pressed(undo.events(asCharacters: true)) == [55, 6])
    #expect(pressed(withOption.events(asCharacters: true)) == [55, 58, 37])
    #expect(pressed(onScreenControl.events(asCharacters: true, onScreen: .control)) == [59, 8])
  }

  @Test("A shortcut on a letter the US table lacks holds the modifiers around that letter")
  func chordOutsideTheTable() {
    let key = Key(usage: 51, characters: "ö", unmodifiedCharacters: "ö", modifiers: .command)
    #expect(
      key.events(asCharacters: true) == [
        .key(code: 55, down: true, repeatKey: false, modifiers: 8), .text("ö"),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ])
  }

  @Test("Shift in a shortcut stays held around a letter or symbol the US table lacks, and never doubles a letter")
  func shiftedChordOutsideTheTable() {
    func held(around text: String) -> [ScreenSharingInputEvent] {
      [
        .key(code: 55, down: true, repeatKey: false, modifiers: 8),
        .key(code: 56, down: true, repeatKey: false, modifiers: 9), .text(text),
        .key(code: 56, down: false, repeatKey: false, modifiers: 8),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ]
    }
    for (unmodified, sent) in [("ö", "Ö"), ("ß", "ß"), ("§", "§")] {
      let key = Key(usage: 51, characters: unmodified, unmodifiedCharacters: unmodified, modifiers: [.command, .shift])
      #expect(key.events(asCharacters: true) == held(around: sent), "\(unmodified)")
    }
  }

  @Test("Caps Lock doesn't add Shift to a shortcut, whichever case iOS reports the key in")
  func capsLockedChord() {
    let interrupt = Key(usage: 6, characters: "C", unmodifiedCharacters: "C", modifiers: .control)
    let umlaut = Key(usage: 51, characters: "Ö", unmodifiedCharacters: "Ö", modifiers: .command)
    #expect(pressed(interrupt.events(asCharacters: true)) == [59, 8])
    let dottedI = Key(usage: 12, characters: "İ", unmodifiedCharacters: "İ", modifiers: .command)
    #expect(umlaut.events(asCharacters: true)?.contains(.text("ö")) == true)
    #expect(dottedI.events(asCharacters: true)?.contains(.text("İ")) == true, "its small form is two scalars")
  }

  @Test("A shortcut on a key whose own character is a shifted US symbol doesn't gain a Shift")
  func chordOnAUSShiftedSymbol() {
    let frenchAmpersand = Key(usage: 30, characters: "&", unmodifiedCharacters: "&", modifiers: .command)
    #expect(
      frenchAmpersand.events(asCharacters: true) == [
        .key(code: 55, down: true, repeatKey: false, modifiers: 8), .text("&"),
        .key(code: 55, down: false, repeatKey: false, modifiers: 0),
      ])
  }

  @Test("A dead key, which has no character yet, sends nothing to a desktop that takes characters")
  func deadKey() {
    let deadAcute = Key(usage: 46, unmodifiedCharacters: "´")
    let optionDeadKey = Key(usage: 8, unmodifiedCharacters: "e", modifiers: .option)
    let controlPicture = Key(usage: 46, characters: "\u{1b}", unmodifiedCharacters: "\u{1b}")
    #expect(deadAcute.events(asCharacters: true) == [])
    #expect(deadAcute.events(asCharacters: true, onScreen: .option) == [])
    #expect(deadAcute.events(asCharacters: true, onScreen: .control) == [])
    #expect(optionDeadKey.events(asCharacters: true) == [])
    #expect(pressed(controlPicture.events(asCharacters: true)) == [24], "not a dead key: it has characters")
    #expect(pressed(deadAcute.events(asCharacters: false)) == [24])
  }

  @Test("The key after a dead key carries what iOS made of the two: the accented letter, the accent, or both")
  func afterADeadKey() {
    let combined = Key(usage: 8, characters: "é", unmodifiedCharacters: "e")
    let accentAlone = Key(usage: 44, characters: "´", unmodifiedCharacters: " ")
    let combiningAccent = Key(usage: 44, characters: " \u{301}", unmodifiedCharacters: " ")
    #expect(combiningAccent.events(asCharacters: true) == [.text(" \u{301}")])
    let notCombined = Key(usage: 27, characters: "´x", unmodifiedCharacters: "x")
    #expect(combined.events(asCharacters: true) == [.text("é")])
    #expect(accentAlone.events(asCharacters: true) == [.text("´")])
    #expect(
      notCombined.events(asCharacters: true) == [
        .text("´"), .key(code: 7, down: true, repeatKey: false, modifiers: 0),
        .key(code: 7, down: false, repeatKey: false, modifiers: 0),
      ])
    #expect(notCombined.events(asCharacters: true, onScreen: .shift)?.first == .text("´"))
    #expect(pressed(notCombined.events(asCharacters: true, onScreen: .shift)) == [56, 7])
  }

  @Test("Space by itself stays a key position, so Shift, Option and Command with Space still arrive")
  func space() {
    let shiftSpace = Key(usage: 44, characters: " ", unmodifiedCharacters: " ", modifiers: .shift)
    let optionSpace = Key(usage: 44, characters: "\u{a0}", unmodifiedCharacters: " ", modifiers: .option)
    let wideSpace = Key(usage: 44, characters: "\u{3000}", unmodifiedCharacters: " ", modifiers: .shift)
    #expect(pressed(wideSpace.events(asCharacters: true)) == [56, 49])
    #expect(pressed(shiftSpace.events(asCharacters: true)) == [56, 49])
    #expect(pressed(optionSpace.events(asCharacters: true)) == [58, 49])
  }

  @Test("A shortcut on a key iOS gives no character for goes by the key's position, not nowhere")
  func chordWithoutACharacter() {
    let key = Key(usage: 46, modifiers: .command)
    #expect(pressed(key.events(asCharacters: true)) == [55, 24])
  }

  @Test("Keys that have no character go by position")
  func keysWithoutACharacter() {
    let left = Key(usage: 80, characters: "UIKeyInputLeftArrow", unmodifiedCharacters: "UIKeyInputLeftArrow")
    #expect(pressed(left.events(asCharacters: true)) == [123])
    #expect(pressed(left.events(asCharacters: true, onScreen: .shift)) == [56, 123])
  }

  @Test("A key Codevisor has no position for is left to the system")
  func unknownKey() {
    #expect(Key(usage: 225).events(asCharacters: false) == nil)
    #expect(Key(usage: 225).events(asCharacters: true) == nil)
  }
}
