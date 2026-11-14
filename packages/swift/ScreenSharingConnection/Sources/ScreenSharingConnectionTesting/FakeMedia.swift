import CodevisorClient
import Foundation
import Observation
import ScreenSharing
import ScreenSharingV2

@MainActor
@Observable
public final class FakeMedia {
  public nonisolated static let address = ServerScreenSharingMediaAddress(
    endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: ["192.168.1.2:4433"])

  public var endpointId = FakeMedia.address.endpointId
  public var connectFails = false
  public var handshakeHangs = false
  public private(set) var sessions: [LoopbackSession] = []

  public init() {}

  public var connector: ScreenSharingV2Connector {
    ScreenSharingV2Connector(
      address: { [weak self] in
        ServerScreenSharingMediaAddress(
          endpointId: self?.endpointId ?? Self.address.endpointId, relayUrl: nil, directAddrs: Self.address.directAddrs)
      },
      connect: { [weak self] _ in
        guard let self, !connectFails else {
          throw ScreenSharingError.unavailable("No route to the host in this test.")
        }

        let session = LoopbackSession(hangsInHandshake: handshakeHangs)
        sessions.append(session)
        return session
      })
  }
}
