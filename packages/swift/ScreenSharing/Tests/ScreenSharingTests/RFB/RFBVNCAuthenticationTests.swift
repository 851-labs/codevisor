import Foundation
import Testing
@testable import ScreenSharing

/// VNC Authentication (RFC 6143 §7.2.2): DES-ECB over the 16-byte challenge,
/// keyed by the password's first eight bytes with each byte's bits mirrored.
struct RFBVNCAuthenticationTests {
  /// FIPS PUB 81, Appendix B: DES key 0x0123456789ABCDEF over the plaintext
  /// "Now is t" (0x4E6F772069732074) gives 0x3FA40E8A984D4815. VNC mirrors the
  /// bits of every key byte, so the password whose key is that FIPS key is the
  /// mirror image 0x80C4A2E691D5B3F7 — the anchor for everything else here.
  static let fipsPassword = "\u{80}\u{c4}\u{a2}\u{e6}\u{91}\u{d5}\u{b3}\u{f7}"

  @Test func matchesTheFIPS81KnownAnswerOnBothECBBlocks() {
    let challenge = Array("Now is t".utf8) + Array("Now is t".utf8)
    let response = RFBVNCAuthentication.response(challenge: challenge, password: Self.fipsPassword)
    #expect(response == [UInt8](hex: "3fa40e8a984d4815 3fa40e8a984d4815"))
  }

  /// ECB, so each half is encrypted alone: swapping the halves of the
  /// challenge swaps the halves of the response, with no chaining between them.
  @Test func theTwoBlocksAreEncryptedIndependently() {
    let first = Array("Now is t".utf8), second = Array("he time!".utf8)
    let forward = RFBVNCAuthentication.response(challenge: first + second, password: Self.fipsPassword)
    let reversed = RFBVNCAuthentication.response(challenge: second + first, password: Self.fipsPassword)
    #expect(Array(forward.prefix(8)) == Array(reversed.suffix(8)))
    #expect(Array(forward.suffix(8)) == Array(reversed.prefix(8)))
    #expect(Array(forward.prefix(8)) == [UInt8](hex: "3fa40e8a984d4815"))
  }

  @Test func onlyTheFirstEightBytesOfThePasswordAreTheKey() {
    let challenge = [UInt8](0..<16)
    let eight = RFBVNCAuthentication.response(challenge: challenge, password: "12345678")
    #expect(RFBVNCAuthentication.response(challenge: challenge, password: "123456789") == eight)
    #expect(RFBVNCAuthentication.response(challenge: challenge, password: "12345678anything at all") == eight)
    // The truncation is at eight bytes, not eight characters: the ninth byte is dropped, the eighth is not.
    #expect(RFBVNCAuthentication.response(challenge: challenge, password: "1234567") != eight)
  }

  /// A short password is zero-padded, so it is indistinguishable from the same
  /// password written out with explicit NULs.
  @Test func shortPasswordsArePaddedWithZeroBytes() {
    let challenge = [UInt8](0..<16)
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "ab")
        == RFBVNCAuthentication.response(challenge: challenge, password: "ab\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}"))
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "")
        == RFBVNCAuthentication.response(challenge: challenge, password: "\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}"))
  }

  /// The key is Latin-1 bytes: anything outside it becomes "?" exactly as
  /// `clientCutText` treats it, so the same password reaches the same key.
  @Test func theKeyIsLatin1Bytes() {
    let challenge = [UInt8](0..<16)
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "é")
        == RFBVNCAuthentication.response(challenge: challenge, password: "\u{e9}"))
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "→")
        == RFBVNCAuthentication.response(challenge: challenge, password: "?"))
  }

  @Test func differentPasswordsAndChallengesGiveDifferentResponses() {
    let challenge = [UInt8](0..<16)
    let response = RFBVNCAuthentication.response(challenge: challenge, password: "secret")
    #expect(response == [UInt8](hex: "ee22539f33a5983ec12f9c2edbc995dd"))
    #expect(RFBVNCAuthentication.response(challenge: challenge, password: "Secret") != response)
    #expect(RFBVNCAuthentication.response(challenge: [UInt8](1..<17), password: "secret") != response)
    #expect(response.count == 16)
  }

  /// The mirroring is per byte, not over the whole key, so two passwords that
  /// are byte reversals of each other do not collide.
  @Test func bitsAreMirroredWithinEachKeyByte() {
    let challenge = [UInt8](repeating: 0, count: 16)
    // 0x02 mirrors to 0x40 and 0x40 to 0x02: the same two bytes, opposite keys.
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "\u{02}")
        != RFBVNCAuthentication.response(challenge: challenge, password: "\u{40}"))
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "\u{01}\u{02}")
        != RFBVNCAuthentication.response(challenge: challenge, password: "\u{02}\u{01}"))
  }

  /// DES throws away the low bit of every key byte, so two passwords that
  /// differ only there authenticate identically. That is the cipher, not this
  /// code, but it is the reason a "wrong" password can still be accepted.
  @Test func theLowBitOfEachKeyByteIsParityAndCarriesNothing() {
    let challenge = [UInt8](0..<16)
    // Mirrored, 0x81 stays 0x81 while 0x01 becomes 0x80 — one parity bit apart.
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "\u{81}")
        == RFBVNCAuthentication.response(challenge: challenge, password: "\u{01}"))
  }
}
