import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingV2
import Synchronization

enum ScreenSharingStreamMedia: Equatable {
  case v2(viewerEndpointId: String)
  case webRTC(offer: String)

  init?(_ request: ServerScreenSharingRequest) {
    if request.engine == ScreenSharingEngine.v2.rawValue {
      guard let media = request.media else { return nil }

      self = .v2(viewerEndpointId: media.endpointId)
    } else {
      guard let offer = request.offer, offer.utf8.count <= 256 * 1024, offer.contains("a=fingerprint:sha-256 ") else {
        return nil
      }

      self = .webRTC(offer: offer)
    }
  }
}

enum ScreenSharingStreamGrant: Equatable {
  case media(ServerScreenSharingMediaGrant)
  case answer(String)
}

extension ServerScreenSharingReply {
  static func connecting(_ grant: ScreenSharingStreamGrant, message: String? = nil) -> Self {
    switch grant {
    case .media(let media):
      var reply = Self(status: "connecting", message: message)
      reply.media = media
      return reply
    case .answer(let answer):
      return Self(status: "connecting", message: message, answer: answer)
    }
  }
}

@MainActor
final class ScreenSharingV2StreamLink {
  static let acceptTimeout: Duration = .seconds(20)

  let link: ScreenSharingV2HostLink
  nonisolated let frames: ScreenSharingV2LatestFrame
  private let token = ScreenSharingHostSession.makeToken()
  private var accepting: Task<Void, Never>?
  private var closed = false

  init(configuration: ScreenSharingVideoConfiguration) {
    link = ScreenSharingV2HostLink(configuration: configuration, metrics: ScreenSharingMetrics())
    frames = ScreenSharingV2LatestFrame(router: link.frameRouter)
  }

  func listen(
    for viewerEndpointId: String, failed: @escaping @MainActor (String) -> Void
  ) async throws -> ScreenSharingStreamGrant {
    guard let endpoint = await ScreenSharingMediaEndpoint.shared.ready() else {
      throw ScreenSharingError.unavailable("This Mac's screen-sharing endpoint isn't available.")
    }
    guard !closed else { throw CancellationError() }

    let ticket = ScreenSharingV2Acceptor.shared.expect(viewerEndpointId, token: token, on: endpoint)
    let token = token
    let link = link
    let frames = frames
    accepting = Task { [weak self] in
      do {
        let connection = try await ScreenSharingV2Acceptor.shared.connection(ticket, timeout: Self.acceptTimeout)
        try await link.accept(connection) { [weak self] presented in
          guard let self, !self.closed, presented == token else { return "This stream ended." }

          return nil
        }
        frames.replay()
      } catch {
        guard !Task.isCancelled, let self, !self.closed else { return }

        failed("The viewer couldn't connect over engine v2.")
      }
    }
    let address = ScreenSharingMediaEndpoint.address(of: endpoint)
    return .media(
      .init(endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs, token: token))
  }

  func close() {
    guard !closed else { return }

    closed = true
    accepting?.cancel()
    link.close()
  }
}

final class ScreenSharingV2LatestFrame: ScreenSharingFrameSink {
  private let router: ScreenSharingV2FrameRouter
  private let latest = Mutex<ScreenSharingVideoFrame?>(nil)

  init(router: ScreenSharingV2FrameRouter) {
    self.router = router
  }

  func push(_ frame: ScreenSharingVideoFrame) {
    latest.withLock { $0 = frame }
    router.push(frame)
  }

  func replay() {
    guard let frame = latest.withLock({ $0 }) else { return }

    router.push(frame)
  }
}
