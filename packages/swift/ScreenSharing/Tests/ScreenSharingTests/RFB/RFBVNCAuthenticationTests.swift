import Foundation
import Testing
@testable import ScreenSharing

struct RFBVNCAuthenticationTests {
  static let fipsPassword = "\u{80}\u{c4}\u{a2}\u{e6}\u{91}\u{d5}\u{b3}\u{f7}"

  @Test func matchesTheFIPS81KnownAnswerOnBothECBBlocks() {
    let challenge = Array("Now is t".utf8) + Array("Now is t".utf8)
    let response = RFBVNCAuthentication.response(challenge: challenge, password: Self.fipsPassword)
    #expect(response == [UInt8](hex: "3fa40e8a984d4815 3fa40e8a984d4815"))
  }

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
    #expect(RFBVNCAuthentication.response(challenge: challenge, password: "1234567") != eight)
  }

  @Test func shortPasswordsArePaddedWithZeroBytes() {
    let challenge = [UInt8](0..<16)
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "ab")
        == RFBVNCAuthentication.response(challenge: challenge, password: "ab\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}"))
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "")
        == RFBVNCAuthentication.response(challenge: challenge, password: "\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}"))
  }

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

  @Test func bitsAreMirroredWithinEachKeyByte() {
    let challenge = [UInt8](repeating: 0, count: 16)
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "\u{02}")
        != RFBVNCAuthentication.response(challenge: challenge, password: "\u{40}"))
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "\u{01}\u{02}")
        != RFBVNCAuthentication.response(challenge: challenge, password: "\u{02}\u{01}"))
  }

  @Test func theLowBitOfEachKeyByteIsParityAndCarriesNothing() {
    let challenge = [UInt8](0..<16)
    #expect(
      RFBVNCAuthentication.response(challenge: challenge, password: "\u{81}")
        == RFBVNCAuthentication.response(challenge: challenge, password: "\u{01}"))
  }
}
