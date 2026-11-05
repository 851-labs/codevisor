import CodevisorClient
import CodevisorNet
import Foundation
import ScreenSharing
import ScreenSharingV2

extension ScreenSharingHostService {
  static let v2AcceptTimeout: Duration = .seconds(20)

  func startV2(_ session: ScreenSharingHostSession, token: String) async -> ServerScreenSharingReply {
    guard let endpoint = await mediaEndpointHandle() else {
      await end(session)
      return .init(status: "failed", message: "This Mac's screen-sharing endpoint isn't available.")
    }
    guard current === session, !session.stopping else { return .init(status: "stopped") }

    acceptV2(session, on: endpoint)
    let address = ScreenSharingMediaEndpoint.address(of: endpoint)
    var reply = ServerScreenSharingReply(status: "connecting")
    reply.media = .init(
      endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs, token: token)
    return reply
  }

  private func acceptV2(_ session: ScreenSharingHostSession, on endpoint: NetEndpointHandle) {
    guard let v2 = session.v2, let link = session.peer as? ScreenSharingV2HostLink else { return }

    let ticket = ScreenSharingV2Acceptor.shared.expect(v2.viewerEndpointId, token: v2.token, on: endpoint)
    session.mediaAccept = Task { [weak self, weak session] in
      do {
        let connection = try await ScreenSharingV2Acceptor.shared.connection(ticket, timeout: Self.v2AcceptTimeout)
        try await link.accept(connection) { [weak session] token in
          guard let session, !session.stopping, token == v2.token else { return "This screen-sharing session ended." }
          return nil
        }
      } catch {
        guard !Task.isCancelled, let self, let session else { return }

        Self.logger.notice("Engine v2 viewer didn't connect: \(error.localizedDescription, privacy: .public)")
        await self.end(session, reason: "The viewer couldn't connect to this Mac over engine v2.")
      }
    }
  }
}
