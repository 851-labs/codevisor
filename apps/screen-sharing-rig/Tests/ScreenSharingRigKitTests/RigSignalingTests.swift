import ScreenSharing
import ScreenSharingWebRTC
import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigSignalingTests {
  /// The host rejects offers whose `version` is not 1, so viewers must send exactly that.
  @Test func offerDeclaresProtocolVersionOne() throws {
    let offer = RigOfferRequest(
      sessionID: "s1", offer: ScreenSharingDescription(kind: "offer", sdp: "v=0"), build: .unknown, name: "viewer")
    #expect(String(decoding: try RigJSON.encode(offer), as: UTF8.self).contains(#""version":1"#))
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
