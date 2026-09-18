import ScreenSharing
import ScreenSharingWebRTC
import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigSignalingTests {
  @Test func offerAndAnswerRoundTripThroughJSON() throws {
    let build = RigBuildInfo(commit: "abcdef1234567890", dirty: true, configuration: "release", builtAt: "t")
    let offer = RigOfferRequest(
      sessionID: "s1", offer: ScreenSharingDescription(kind: "offer", sdp: "v=0"), build: build, name: "viewer")
    let decoded = try RigJSON.decode(RigOfferRequest.self, from: try RigJSON.encode(offer))
    #expect(decoded.version == 1)
    #expect(decoded.sessionID == "s1")
    #expect(decoded.offer.kind == "offer")
    #expect(decoded.offer.sdp == "v=0")
    #expect(decoded.build == build)
    #expect(decoded.name == "viewer")
    let answer = RigAnswerResponse(
      sessionID: "s1", answer: ScreenSharingDescription(kind: "answer", sdp: "v=1"), build: build, name: "host")
    let decodedAnswer = try RigJSON.decode(RigAnswerResponse.self, from: try RigJSON.encode(answer))
    #expect(decodedAnswer.answer.sdp == "v=1")
    #expect(decodedAnswer.name == "host")
  }

  @Test func buildInfoReadsPlistKeysAndLabels() {
    let info = RigBuildInfo(infoDictionary: [
      "CodevisorRigCommit": "0123456789abcdef", "CodevisorRigDirty": "true",
      "CodevisorProbeBuildConfiguration": "release", "CodevisorRigBuiltAt": "2026-09-14T00:00:00Z",
    ])
    #expect(info.commit == "0123456789abcdef")
    #expect(info.dirty)
    #expect(info.label == "01234567* release")
    let absent = RigBuildInfo(infoDictionary: nil)
    #expect(absent.commit == "unknown")
    #expect(!absent.dirty)
    #expect(absent.label == "unknown unspecified")
    let boolean = RigBuildInfo(infoDictionary: ["CodevisorRigDirty": true])
    #expect(boolean.dirty)
  }

  @Test func encodingIsKeySorted() throws {
    let data = try RigJSON.encode(
      RigStatus(
        role: "host", name: "n", build: .unknown, connection: "new", sessionID: nil, peerName: nil, peerBuild: nil,
        uptimeSeconds: 1, reconnects: 0, capture: "synthetic", hud: true))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix(#"{"build":"#))
    #expect(text.contains(#""capture":"synthetic""#))
  }
}
