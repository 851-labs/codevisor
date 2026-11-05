import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingV2
import Synchronization

struct ScreenSharingStreamMedia: Equatable {
  let viewerEndpointId: String

  init(viewerEndpointId: String) {
    self.viewerEndpointId = viewerEndpointId
  }

  init?(_ request: ServerScreenSharingRequest) {
    guard request.engine == ScreenSharingEngine.v2.rawValue, let media = request.media else { return nil }

    viewerEndpointId = media.endpointId
  }
}

extension ServerScreenSharingReply {
  static func connecting(_ grant: ServerScreenSharingMediaGrant, message: String? = nil) -> Self {
    var reply = Self(status: "connecting", message: message)
    reply.media = grant
    return reply
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

  init(configuration: ScreenSharingVideoConfiguration, encoder: ScreenSharingV2EncoderKind = .configured()) {
    link = ScreenSharingV2HostLink(configuration: configuration, metrics: ScreenSharingMetrics()) {
      configuration, metrics in
      try await ScreenSharingV2Encoders.make(encoder, configuration: configuration, metrics: metrics)
    }
    frames = ScreenSharingV2LatestFrame(router: link.frameRouter)
  }

  func listen(
    for viewerEndpointId: String, failed: @escaping @MainActor (String) -> Void
  ) async throws -> ServerScreenSharingMediaGrant {
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
    return .init(
      endpointId: address.endpointId, relayUrl: address.relayUrl, directAddrs: address.directAddrs, token: token)
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
