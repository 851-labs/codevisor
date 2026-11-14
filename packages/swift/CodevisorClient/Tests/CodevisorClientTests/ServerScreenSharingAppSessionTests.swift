import CryptoKit
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

  @Test func theSignedMessageIsTheEightAgreedLinesInOrder() throws {
    let start = Self.start(display: "0E7B7B5C-6C1D-4E0F-9B1A-2D3C4B5A6F70")
    let message = try #require(
      ServerScreenSharingProof.message(
        for: start, hostKey: String(repeating: "B", count: 64), nonce: String(repeating: "C", count: 64)))

    #expect(
      String(decoding: message, as: UTF8.self)
        == [
          "codevisor.screen-sharing.start.v1", "start", String(repeating: "b", count: 64),
          String(repeating: "c", count: 64), Self.key.publicKey.rawRepresentation.hexEncoded,
          "11111111-2222-3333-4444-555555555555", "attach", "0E7B7B5C-6C1D-4E0F-9B1A-2D3C4B5A6F70",
        ].joined(separator: "\n"))
    let withoutTarget = try #require(
      ServerScreenSharingProof.message(for: Self.start(display: nil), hostKey: "b", nonce: "c"))
    #expect(String(decoding: withoutTarget, as: UTF8.self).hasSuffix("\nattach\n"))
  }

  @Test func aProofCoversTheOperationHostNonceKeyAttemptIntentAndTarget() throws {
    let start = Self.start(display: "display")
    let challenge = ServerScreenSharingChallenge(
      hostKey: String(repeating: "b", count: 64), nonce: String(repeating: "c", count: 64))
    let signer = ScreenSharingStartSigner(key: Self.key.publicKey.rawRepresentation.hexEncoded) {
      try Self.key.signature(for: $0)
    }
    let proof = try ServerScreenSharingProof(of: start, answering: challenge, signer: signer)
    #expect(proof.nonce == challenge.nonce && proof.signature.count == 128)
    #expect(proof.proves(start, to: challenge.hostKey))

    var restart = ServerScreenSharingRequest(
      operation: .restart, workspaceId: start.workspaceId, paneId: start.paneId, viewerId: start.viewerId,
      displayId: start.displayId)
    restart.app = start.app
    restart.intent = start.intent
    var open = start
    open.intent = .open
    var otherTarget = start
    otherTarget.displayId = "other"
    var otherKey = start
    otherKey.app = .init(key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.hexEncoded, name: "Other")
    var otherAttempt = ServerScreenSharingRequest(
      operation: .start, workspaceId: start.workspaceId, paneId: start.paneId, viewerId: UUID(),
      displayId: start.displayId)
    otherAttempt.app = start.app
    otherAttempt.intent = start.intent
    for changed in [restart, open, otherTarget, otherKey, otherAttempt] {
      #expect(!proof.proves(changed, to: challenge.hostKey))
    }
    #expect(!proof.proves(start, to: String(repeating: "d", count: 64)))
    let otherNonce = ServerScreenSharingProof(nonce: String(repeating: "d", count: 64), signature: proof.signature)
    #expect(!otherNonce.proves(start, to: challenge.hostKey))
    #expect(!ServerScreenSharingProof(nonce: proof.nonce, signature: "not hex").proves(start, to: challenge.hostKey))
  }

  private static let key = Curve25519.Signing.PrivateKey()

  private static func start(display: String?) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .start, workspaceId: UUID(), paneId: UUID(),
      viewerId: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(), displayId: display)
    request.app = .init(key: key.publicKey.rawRepresentation.hexEncoded.uppercased(), name: "Alexandru's MacBook Pro")
    request.intent = .attach
    return request
  }
}
