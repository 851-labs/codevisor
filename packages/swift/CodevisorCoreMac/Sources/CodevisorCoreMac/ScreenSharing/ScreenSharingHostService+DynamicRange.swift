import ScreenSharing
import ScreenSharingWebRTC

extension ScreenSharingHostService {
  struct DynamicRangeState {
    /// Whether the viewer's screen can show HDR, as it last said.
    var viewerSupports = false
    /// The last switch, which the next one waits for.
    var task: Task<Void, Never>?
    /// What the viewer was last told.
    var reported: (range: ScreenSharingDynamicRange, reason: String?)?
  }

  /// HDR for a native viewer (851-2380): the viewer says on the video format channel whether its
  /// screen can show HDR; the host captures and encodes 10-bit Display P3 PQ while that holds and
  /// the display it captures has headroom, and says what it sends. An older viewer never opens
  /// the channel, and the session stays SDR.
  func configureVideoFormat(_ session: Session) {
    session.peer.videoFormatChannel.onMessage = { [weak self, weak session] message in
      guard let self, let session, !session.stopping, case .viewer(let supported) = message else { return }
      session.hdr.viewerSupports = supported
      self.applyDynamicRange(session)
    }
  }

  /// Brings the capture to the range the viewer and the captured display allow. Called when the
  /// viewer reports its screen and before each capture start (the display may have changed).
  /// Switches run one at a time, in order; the task finishes once this one has.
  @discardableResult
  func applyDynamicRange(_ session: Session) -> Task<Void, Never> {
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
