import Foundation
import Testing
@testable import ScreenSharing

/// The wire constants and the messages a user is shown when they go wrong.
struct RFBProtocolTypesTests {
  /// The numbers are the protocol's, not ours: changing one silently talks to
  /// a different encoding.
  @Test func encodingsUseTheirRegisteredNumbers() {
    #expect(RFBEncoding.raw.rawValue == 0)
    #expect(RFBEncoding.copyRect.rawValue == 1)
    #expect(RFBEncoding.tight.rawValue == 7)
    #expect(RFBEncoding.zrle.rawValue == 16)
    #expect(RFBEncoding.desktopSize.rawValue == -223)
    #expect(RFBEncoding.cursor.rawValue == -239)
    #expect(RFBEncoding.pointerPosition.rawValue == -232)
    #expect(RFBEncoding.fence.rawValue == -312)
    #expect(RFBEncoding.continuousUpdates.rawValue == -313)
    #expect(RFBEncoding.extendedDesktopSize.rawValue == -308)
    #expect(UInt32(bitPattern: RFBEncoding.extendedClipboard.rawValue) == 0xC0A1_E5CE)
    #expect(
      Set(RFBEncoding.allCases) == [
        .raw, .copyRect, .tight, .zrle, .desktopSize, .cursor, .pointerPosition, .fence, .continuousUpdates,
        .extendedDesktopSize, .extendedClipboard,
      ])
  }

  /// SetEncodings is a preference list, so the order is meaningful: the
  /// cheapest-to-decode real encoding first, pseudo-encodings last.
  @Test func supportedEncodingsAreAdvertisedInPreferenceOrder() {
    #expect(
      RFBEncoding.supported == [
        .tight, .zrle, .copyRect, .raw, .desktopSize, .cursor, .pointerPosition, .fence, .continuousUpdates,
        .extendedDesktopSize, .extendedClipboard,
      ])
    #expect(RFBEncoding.supported.map(\.rawValue) == [7, 16, 1, 0, -223, -239, -232, -312, -313, -308, -1_063_131_698])
    #expect(Set(RFBEncoding.supported) == Set(RFBEncoding.allCases))
  }

  @Test(arguments: [Int32(2), 5, 15, 17, -222, -224, Int32.max, Int32.min])
  func encodingsOutsideTheSetHaveNoCase(_ raw: Int32) {
    #expect(RFBEncoding(rawValue: raw) == nil)
  }

  @Test func securityTypesUseTheirRegisteredNumbers() {
    #expect(RFBSecurityType.none.rawValue == 1)
    #expect(RFBSecurityType.vncAuthentication.rawValue == 2)
    #expect(RFBSecurityType.appleRemoteDesktop.rawValue == 30)
  }

  /// 0 is "connection failed" rather than a security type, and 16/18/19 are
  /// Tight, TLS and VeNCrypt — real types this client does not implement.
  @Test(arguments: [UInt8(0), 3, 5, 16, 18, 19, 20, 29, 31, 255])
  func unimplementedSecurityTypesHaveNoCase(_ raw: UInt8) {
    #expect(RFBSecurityType(rawValue: raw) == nil)
  }

  /// A Mac offering only type 30 needs a settings change, not a better
  /// password, so it gets its own instruction.
  @Test func appleRemoteDesktopGetsItsOwnAdvice() {
    let message = RFBError.securityUnsupported([30]).errorDescription
    #expect(message?.contains("Apple Remote Desktop") == true)
    #expect(message?.contains("Screen Sharing settings") == true)
    // Still the right advice when it is one of several offered types.
    #expect(RFBError.securityUnsupported([16, 30, 18]).errorDescription == message)
  }

  @Test func otherUnsupportedSecurityTypesAreListedByNumber() {
    #expect(
      RFBError.securityUnsupported([16, 18, 19]).errorDescription
        == "The VNC server requires an unsupported authentication method (16, 18, 19).")
    #expect(
      RFBError.securityUnsupported([]).errorDescription
        == "The VNC server requires an unsupported authentication method ().")
  }

  /// An authentication failure shows the server's own words, so the user sees
  /// "password expired" rather than a generic refusal.
  @Test func everyErrorHasAUserFacingDescription() {
    #expect(RFBError.connectionClosed.errorDescription == "The VNC server closed the connection.")
    #expect(RFBError.protocolMismatch("no RFB greeting").errorDescription == "Not a VNC server: no RFB greeting")
    #expect(RFBError.authenticationFailed("Password expired").errorDescription == "Password expired")
    #expect(
      RFBError.unsupportedEncoding(-313).errorDescription == "The VNC server sent an unsupported encoding (-313).")
    #expect(
      RFBError.malformed("ZRLE truncated").errorDescription == "The VNC server sent an invalid message: ZRLE truncated")
    #expect(RFBError.transport("No route to host.").errorDescription == "No route to host.")
    let every: [RFBError] = [
      .connectionClosed, .protocolMismatch(""), .securityUnsupported([]), .authenticationFailed(""),
      .unsupportedEncoding(0), .malformed(""), .transport(""),
    ]
    for error in every { #expect(error.errorDescription != nil) }
  }

  /// Equality is what the tests and the session's retry logic compare on, so
  /// the payload has to participate.
  @Test func errorsCompareOnTheirPayload() {
    #expect(RFBError.malformed("a") != RFBError.malformed("b"))
    #expect(RFBError.malformed("a") == RFBError.malformed("a"))
    #expect(RFBError.securityUnsupported([1, 2]) != RFBError.securityUnsupported([2, 1]))
    #expect(RFBError.unsupportedEncoding(1) != RFBError.unsupportedEncoding(2))
    #expect(RFBError.protocolMismatch("x") != RFBError.transport("x"))
  }

  @Test func rectanglesMeasureFromTheirOrigin() {
    let rect = RFBRectangle(x: 10, y: 20, width: 30, height: 40)
    #expect(rect.maxX == 40)
    #expect(rect.maxY == 60)
    #expect(!rect.isEmpty)
  }

  /// A zero-width or zero-height rectangle is legal on the wire and means "no
  /// pixels", which CopyRect must treat as a no-op rather than a fault.
  @Test(arguments: [(0, 5), (5, 0), (0, 0), (-1, 5), (5, -1)])
  func rectanglesWithNoAreaAreEmpty(_ width: Int, _ height: Int) {
    #expect(RFBRectangle(x: 0, y: 0, width: width, height: height).isEmpty)
  }

  @Test func versionsOrderByMajorThenMinor() {
    #expect(RFBProtocolVersion.v3_3 < .v3_7)
    #expect(RFBProtocolVersion.v3_7 < .v3_8)
    #expect(RFBProtocolVersion(major: 3, minor: 889) < RFBProtocolVersion(major: 4, minor: 0))
    #expect(RFBProtocolVersion(major: 3, minor: 8) == .v3_8)
  }
}
