import Foundation
import Testing
@testable import CodevisorClient

/// 851-2339: `setScale` and the display's scale fields, as codevisor-server sends and reads them.
struct ServerScreenSharingScaleTests {
  @Test func setScaleEncodesItsOperationAndScale() throws {
    let request = ServerScreenSharingRequest(
      operation: .setScale, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: "vnc:5901", scale: 2)
    let json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(json["operation"] as? String == "setScale")
    #expect(json["scale"] as? Int == 2)
  }

  @Test func aScalableDisplayDecodesItsScalesAndDefaultSize() throws {
    let reply = try JSONDecoder().decode(
      ServerScreenSharingReply.self,
      from: Data(
        #"{"version":1,"status":"available","provider":"vnc","displays":[{"id":"vnc:5901","name":"Desktop","width":0,"height":0,"scales":[1,2],"defaultWidth":1440,"defaultHeight":900}]}"#
          .utf8))
    let display = try #require(reply.displays.first)
    #expect(display.scales == [1, 2] && display.defaultWidth == 1440 && display.defaultHeight == 900)
    // An older server's reply, without them, still decodes.
    let old = try JSONDecoder().decode(
      ServerScreenSharingReply.self,
      from: Data(
        #"{"version":1,"status":"available","displays":[{"id":"1","name":"Main","width":10,"height":10}]}"#.utf8))
    #expect(old.displays.first?.scales == nil)
  }
}
