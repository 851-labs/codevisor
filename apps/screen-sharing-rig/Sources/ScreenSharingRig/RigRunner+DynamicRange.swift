#if os(macOS)
  import ScreenSharing
  import ScreenSharingWebRTC

  extension RigRunner {
    func installVideoFormat(in session: RigSession) {
      guard let peer = session.peer as? ScreenSharingSender else { return }
      peer.videoFormatChannel.onMessage = { [weak self, weak session] message in
        guard case .viewer(let supported) = message, let self, let session, !session.closed else { return }
        session.viewerHighDynamicRange = supported
        self.log("viewer HDR: \(supported ? "yes" : "no")")
        Task { await self.applyDynamicRange(in: session) }
      }
    }

    func applyDynamicRange(in session: RigSession) async {
      guard let peer = session.peer as? ScreenSharingSender, let capture = session.capture else { return }
      let decision = ScreenSharingDynamicRangePolicy.decide(
        viewerSupports: session.viewerHighDynamicRange, codec: session.codec,
        displayHeadroom: session.controlDisplayID.map(ScreenSharingDynamicRangePolicy.headroom) ?? 1)
      var sent = decision
      do {
        try await capture.setDynamicRange(decision.range)
      } catch {
        sent = (capture.dynamicRange, error.localizedDescription)
      }
      log("sending \(sent.range.rawValue)\(sent.reason.map { " (\($0))" } ?? "")")
      session.metrics.label("hostDynamicRange", sent.range.rawValue)
      peer.videoFormatChannel.send(.sending(sent.range, reason: sent.reason))
    }
  }
#endif
