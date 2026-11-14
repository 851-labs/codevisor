import CodevisorClient
import CryptoKit
import Foundation
import Testing

@testable import CodevisorCloud

struct CloudTunnelIdentitySigningTests {
  @Test func theNetworkKeyIsAnEd25519KeyWhosePublicHalfIsTheEndpointID() throws {
    for _ in 0..<8 {
      let identity = Self.identity()
      let seed = try #require(Data(hexEncoded: CloudTunnelIdentity.secretKeyHex(for: identity)))
      let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

      #expect(CloudTunnelIdentity.endpointId(for: identity) == key.publicKey.rawRepresentation.hexEncoded)
    }
  }

  @Test func theSignerSignsAStartThatVerifiesUnderTheAppsEndpointID() throws {
    let identity = Self.identity()
    let signer = try CloudTunnelIdentity.screenSharingSigner(for: identity)
    #expect(signer.key == CloudTunnelIdentity.endpointId(for: identity))

    var start = ServerScreenSharingRequest(operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    start.app = .init(key: signer.key, name: "Alexandru's MacBook Pro")
    start.intent = .open
    let challenge = ServerScreenSharingChallenge(
      hostKey: String(repeating: "b", count: 64), nonce: String(repeating: "c", count: 64))
    let proof = try ServerScreenSharingProof(of: start, answering: challenge, signer: signer)

    #expect(proof.proves(start, to: challenge.hostKey))
    #expect(!proof.proves(start, to: String(repeating: "d", count: 64)))
  }

  private static func identity() -> CloudAppDeviceIdentity {
    let pair = CloudChannelCrypto.generateKeyPair()
    return CloudAppDeviceIdentity(deviceId: UUID().uuidString, secretKey: pair.secretKey, publicKey: pair.publicKey)
  }
}
