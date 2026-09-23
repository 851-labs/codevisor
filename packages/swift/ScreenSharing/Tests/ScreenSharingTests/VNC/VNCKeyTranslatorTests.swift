import Carbon.HIToolbox
import Foundation
import Testing
@testable import ScreenSharing

/// Records what the keyboard layout was asked for, so the modifier state the
/// translator hands `UCKeyTranslate` can be asserted rather than inferred from
/// the character that comes back.
final class LayoutCalls: @unchecked Sendable {
  struct Call: Equatable {
    let code: UInt16
    let carbon: UInt32
  }
  private let lock = NSLock()
  private var storage: [Call] = []
  var all: [Call] { lock.withLock { storage } }
  func record(_ code: UInt16, _ carbon: UInt32) { lock.withLock { storage.append(Call(code: code, carbon: carbon)) } }
}

/// Mac key codes to X11 keysyms: which codes bypass the layout, which
/// modifiers reach it, and what happens to keys the layout has no character
/// for.
struct VNCKeyTranslatorTests {
  private func probe(returning scalar: Unicode.Scalar? = "x") -> (LayoutCalls, VNCKeyTranslator) {
    let calls = LayoutCalls()
    return (
      calls,
      VNCKeyTranslator(layout: { code, carbon in
        calls.record(code, carbon)
        return scalar
      })
    )
  }

  // MARK: Modifier state

  /// Shift, Option and Caps Lock are passed through as the Carbon bits
  /// `UCKeyTranslate` expects; Control and Command deliberately are not, so
  /// ⌘C reaches the server as Control plus an unmodified "c" (851-2317).
  @Test(
    arguments: [
      (UInt8(0), UInt32(0)),
      (1, UInt32(shiftKey >> 8)),
      (2, 0),  // Control
      (4, UInt32(optionKey >> 8)),
      (8, 0),  // Command
      (16, UInt32(alphaLock >> 8)),
      (32, 0),  // Fn
      (5, UInt32(shiftKey >> 8) | UInt32(optionKey >> 8)),
      (17, UInt32(shiftKey >> 8) | UInt32(alphaLock >> 8)),
      (21, UInt32(shiftKey >> 8) | UInt32(optionKey >> 8) | UInt32(alphaLock >> 8)),
      (255, UInt32(shiftKey >> 8) | UInt32(optionKey >> 8) | UInt32(alphaLock >> 8)),
    ] as [(UInt8, UInt32)])
  func onlyShiftOptionAndCapsLockReachTheLayout(_ modifiers: UInt8, _ carbon: UInt32) {
    let (calls, translator) = probe()
    _ = translator.keysym(code: 1, modifiers: modifiers)
    #expect(calls.all == [.init(code: 1, carbon: carbon)])
  }

  /// The Carbon bits are the low byte of the Carbon modifier flags, which is
  /// what `UCKeyTranslate` documents — not the flags themselves.
  @Test func theCarbonBitsAreTheShiftedFlags() {
    #expect(UInt32(shiftKey >> 8) == 2)
    #expect(UInt32(optionKey >> 8) == 8)
    #expect(UInt32(alphaLock >> 8) == 4)
  }

  @Test func theKeyCodeIsPassedThroughUnchanged() {
    let (calls, translator) = probe()
    for code in [UInt16(0), 12, 49, 255, 1000] { _ = translator.keysym(code: code, modifiers: 0) }
    #expect(calls.all.map(\.code) == [0, 12, 49, 255, 1000])
  }

  // MARK: Keys that never reach the layout

  @Test(
    arguments: [
      (UInt16(56), RFBKeysym.shiftLeft), (60, RFBKeysym.shiftRight), (59, RFBKeysym.controlLeft),
      (62, RFBKeysym.controlRight), (58, RFBKeysym.altLeft), (61, RFBKeysym.altRight), (57, RFBKeysym.capsLock),
      // ⌘ is Control (851-2317); both ⌘ keys are Control_R, clear of the left Control key.
      (55, RFBKeysym.controlRight), (54, RFBKeysym.controlRight),
    ] as [(UInt16, UInt32)])
  func modifierKeysHaveTheirOwnKeysyms(_ code: UInt16, _ keysym: UInt32) {
    let (calls, translator) = probe()
    #expect(translator.keysym(code: code, modifiers: 0) == keysym)
    // Held with other modifiers they still mean themselves.
    #expect(translator.keysym(code: code, modifiers: 255) == keysym)
    #expect(calls.all.isEmpty)
  }

  @Test(
    arguments: [
      (UInt16(36), RFBKeysym.return), (76, RFBKeysym.keypadEnter), (48, RFBKeysym.tab), (51, RFBKeysym.backSpace),
      (53, RFBKeysym.escape), (117, RFBKeysym.delete), (114, RFBKeysym.insert), (115, RFBKeysym.home),
      (119, RFBKeysym.end), (116, RFBKeysym.pageUp), (121, RFBKeysym.pageDown), (123, RFBKeysym.left),
      (124, RFBKeysym.right), (125, RFBKeysym.down), (126, RFBKeysym.up),
    ] as [(UInt16, UInt32)])
  func navigationKeysHaveTheirOwnKeysyms(_ code: UInt16, _ keysym: UInt32) {
    let (calls, translator) = probe()
    #expect(translator.keysym(code: code, modifiers: 0) == keysym)
    #expect(calls.all.isEmpty)
  }

  /// The twelve function keys are consecutive keysyms from F1, in the order
  /// the Mac's scattered key codes name them.
  @Test func functionKeysCoverF1ThroughF12InOrder() {
    let (_, translator) = probe()
    let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    #expect(codes.map { translator.keysym(code: $0, modifiers: 0) } == (1...12).map { RFBKeysym.function($0) })
    #expect(RFBKeysym.function(1) == 0xffbe)
    #expect(RFBKeysym.function(12) == 0xffc9)
  }

  /// Fn has no X11 keysym at all, so it is dropped rather than guessed at.
  @Test func theFnKeyIsDropped() {
    let (calls, translator) = probe()
    #expect(translator.keysym(code: 63, modifiers: 0) == nil)
    #expect(translator.keysym(code: 63, modifiers: 32) == nil)
    #expect(calls.all.isEmpty)
  }

  // MARK: Keys that do

  @Test func charactersBecomeTheirLatin1Keysyms() {
    #expect(VNCKeyTranslator(layout: { _, _ in "a" }).keysym(code: 0, modifiers: 0) == 0x61)
    #expect(VNCKeyTranslator(layout: { _, _ in "A" }).keysym(code: 0, modifiers: 1) == 0x41)
    #expect(VNCKeyTranslator(layout: { _, _ in "é" }).keysym(code: 0, modifiers: 0) == 0xe9)
    #expect(VNCKeyTranslator(layout: { _, _ in " " }).keysym(code: 49, modifiers: 0) == 0x20)
  }

  /// `UCKeyTranslate` is asked not to hold dead keys, so Option-E on a US
  /// layout comes back as a standalone acute accent and is sent as a real
  /// key rather than vanishing.
  @Test func aDeadKeyIsSentAsItsStandaloneCharacter() {
    #expect(VNCKeyTranslator(layout: { _, _ in "\u{00b4}" }).keysym(code: 14, modifiers: 4) == 0xb4)
    // A combining mark is outside Latin-1 and takes the Unicode keysym range.
    #expect(VNCKeyTranslator(layout: { _, _ in "\u{0301}" }).keysym(code: 14, modifiers: 4) == 0x0100_0301)
  }

  /// A key the layout has no character for produces nothing: the client sends
  /// no KeyEvent rather than a keysym of zero.
  @Test func aKeyTheLayoutCannotProduceIsDropped() {
    let (calls, translator) = probe(returning: nil)
    #expect(translator.keysym(code: 10, modifiers: 0) == nil)
    #expect(calls.all == [.init(code: 10, carbon: 0)])
  }

  /// Only the first scalar is used, so a layout entry that expands to several
  /// characters still yields exactly one keysym.
  @Test func onlyTheFirstScalarOfTheLayoutsAnswerIsUsed() {
    #expect(VNCKeyTranslator(layout: { _, _ in "ß" }).keysym(code: 1, modifiers: 0) == 0xdf)
  }

  /// The layout is consulted once per key, so a translator with no state
  /// gives the same answer every time.
  @Test func translationIsStateless() {
    let (calls, translator) = probe(returning: "z")
    #expect(translator.keysym(code: 6, modifiers: 1) == 0x7a)
    #expect(translator.keysym(code: 6, modifiers: 1) == 0x7a)
    #expect(calls.all.count == 2)
  }
}
