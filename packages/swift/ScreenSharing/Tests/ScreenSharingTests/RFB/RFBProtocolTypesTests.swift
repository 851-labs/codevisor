import Foundation
import Testing
@testable import ScreenSharing

struct RFBProtocolTypesTests {
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
  }

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

  @Test(arguments: [UInt8(0), 3, 5, 16, 18, 19, 20, 29, 31, 255])
  func unimplementedSecurityTypesHaveNoCase(_ raw: UInt8) {
    #expect(RFBSecurityType(rawValue: raw) == nil)
  }

  @Test func appleRemoteDesktopGetsItsOwnAdvice() {
    let message = RFBError.securityUnsupported([30]).errorDescription
    #expect(message?.contains("Apple Remote Desktop") == true)
    #expect(message?.contains("Screen Sharing settings") == true)
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

  @Test func rectanglesMeasureFromTheirOrigin() {
    let rect = RFBRectangle(x: 10, y: 20, width: 30, height: 40)
    #expect(rect.maxX == 40)
    #expect(rect.maxY == 60)
    #expect(!rect.isEmpty)
  }

  @Test(arguments: [(0, 5), (5, 0), (0, 0), (-1, 5), (5, -1)])
  func rectanglesWithNoAreaAreEmpty(_ width: Int, _ height: Int) {
    #expect(RFBRectangle(x: 0, y: 0, width: width, height: height).isEmpty)
  }
}
