import Foundation
import Testing

@testable import CodevisorClient

struct ServerScreenSharingAppSessionTests {
  @Test func anAppStartCarriesItsKeyNameAndIntentUnderTheWireNames() throws {
    var request = ServerScreenSharingRequest(operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    request.app = .init(key: String(repeating: "a", count: 64), name: "Alexandru's MacBook Pro")
    request.intent = .attach
    let json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(json["intent"] as? String == "attach")
    #expect(json["displayId"] == nil)
    #expect(
      json["app"] as? [String: String] == ["key": String(repeating: "a", count: 64), "name": "Alexandru's MacBook Pro"])
  }

  @Test func aReplyDecodesItsReasonHolderDisplayAndAbilitiesAndToleratesAReasonItDoesNotKnow() throws {
    let reply = try JSONDecoder().decode(
      ServerScreenSharingReply.self,
      from: Data(
        #"{"version":1,"status":"failed","message":"Now viewing on Alexandru's iPhone.","reason":"taken-over","holderName":"Alexandru's iPhone","abilities":["app-sessions"],"display":{"id":"1","name":"Main","width":10,"height":10},"displays":[]}"#
          .utf8))
    #expect(reply.reason == .takenOver && reply.holderName == "Alexandru's iPhone")
    #expect(reply.abilities?.contains(ServerScreenSharingReply.appSessions) == true)
    #expect(reply.display == ServerScreenSharingDisplay(id: "1", name: "Main", width: 10, height: 10))

    let later = try JSONDecoder().decode(
      ServerScreenSharingReply.self,
      from: Data(#"{"version":1,"status":"failed","reason":"a-later-reason","displays":[]}"#.utf8))
    #expect(later.reason == ServerScreenSharingReason(rawValue: "a-later-reason"))
    #expect(later.abilities == nil && later.display == nil && later.holderName == nil)
  }
}
