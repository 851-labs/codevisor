import ScreenSharing
import ScreenSharingWebRTC

extension ScreenSharingHostService {
  struct DynamicRangeState {
    var viewerSupports = false
    var task: Task<Void, Never>?
    var reported: (range: ScreenSharingDynamicRange, reason: String?)?
  }

  func configureVideoFormat(_ session: ScreenSharingHostSession) {
    session.peer.videoFormatChannel.onMessage = { [weak self, weak session] message in
      guard let self, let session, !session.stopping, case .viewer(let supported) = message else { return }
      session.hdr.viewerSupports = supported
      self.applyDynamicRange(session)
    }
  }

  @discardableResult
  func applyDynamicRange(_ session: ScreenSharingHostSession) -> Task<Void, Never> {
    let decision = ScreenSharingDynamicRangePolicy.decide(
      viewerSupports: session.hdr.viewerSupports, codec: session.codec,
      displayHeadroom: ScreenSharingDynamicRangePolicy.headroom(of: session.captureDisplayID))
    let task = Task { [weak session, previous = session.hdr.task] in
      await previous?.value
      guard let session, !session.stopping else { return }
      var sent = decision
      do {
        try await session.capture.setDynamicRange(decision.range)
      } catch {
        Self.logger.error("HDR switch failed: \(error.localizedDescription, privacy: .public)")
        sent = (session.capture.dynamicRange, error.localizedDescription)
      }
      session.metrics.label("hostDynamicRange", sent.range.rawValue)
      if session.hdr.reported?.range != sent.range || session.hdr.reported?.reason != sent.reason {
        session.hdr.reported = sent
        Self.logger.notice(
          "Sending \(sent.range.rawValue, privacy: .public)\(sent.reason.map { " (\($0))" } ?? "", privacy: .public)")
        session.peer.videoFormatChannel.send(.sending(sent.range, reason: sent.reason))
      }
    }
    session.hdr.task = task
    return task
  }
}
