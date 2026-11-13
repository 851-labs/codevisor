import CodevisorClient
import Foundation
import Observation
import ScreenSharing
import ScreenSharingV2

@MainActor
@Observable
final class FakeMedia {
  nonisolated static let address = ServerScreenSharingMediaAddress(
    endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: ["192.168.1.2:4433"])

  var connectFails = false
  var handshakeHangs = false
  private(set) var sessions: [LoopbackSession] = []

  var connector: ScreenSharingV2Connector {
    ScreenSharingV2Connector(
      address: { Self.address },
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
