import CodevisorClient
import CodevisorNet
import Foundation
import ScreenSharing
import ScreenSharingV2

extension ScreenSharingHostService {
  static let v2AcceptTimeout: Duration = .seconds(20)

  func startV2(_ session: ScreenSharingHostSession) async -> ServerScreenSharingReply {
    guard let endpoint = await mediaEndpointHandle() else {
      await end(session)
      return .init(status: "failed", message: Self.endpointUnavailable)
    }
    guard current === session, !session.stopping else { return .init(status: "stopped") }

    acceptV2(session, on: endpoint)
    let address = ScreenSharingMediaEndpoint.address(of: endpoint)
    let viewer = session.owner.appKey == nil ? "viewer \(session.owner.viewerId.uuidString.prefix(8))" : "an app"
    Self.logger.notice(
      "Start granted to \(viewer, privacy: .public) (relay \(address.relayUrl ?? "none", privacy: .public), \(address.directAddrs.count) direct)"
    )
    return .connecting(
      .init(
        endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs,
        token: session.v2.token))
  }

  private func acceptV2(_ session: ScreenSharingHostSession, on endpoint: NetEndpointHandle) {
    let v2 = session.v2
    let link = session.peer
    let ticket = ScreenSharingV2Acceptor.shared.expect(v2.viewerEndpointId, token: v2.token, on: endpoint)
    let began = ContinuousClock.now
    session.mediaAccept = Task { [weak self, weak session] in
      do {
        let connection = try await ScreenSharingV2Acceptor.shared.connection(ticket, timeout: Self.v2AcceptTimeout)
        if let self, let session { self.renewLease(for: session) }
        Self.logger.notice(
          "Viewer media connected in \(Self.milliseconds(since: began)) ms over \(connection.route.map { $0.isRelay ? "relay" : "direct" } ?? "an unknown route", privacy: .public)"
        )
        try await link.accept(connection) { [weak session] token in
          guard let session, !session.stopping, token == v2.token else { return "This screen-sharing session ended." }
          return nil
        }
        Self.logger.notice("Viewer media ready in \(Self.milliseconds(since: began)) ms")
        if let self, let session { self.renewLease(for: session) }
      } catch {
        guard !Task.isCancelled, let self, let session else { return }

        Self.logger.notice("Engine v2 viewer didn't connect: \(error.localizedDescription, privacy: .public)")
        await self.end(session, as: .failed("The viewer couldn't connect to this Mac over engine v2."))
      }
    }
  }
}
