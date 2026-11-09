import CodevisorCore
import CodevisorUI
import Foundation
import Observation

@Observable
final class NewChatSendLanding {
  @ObservationIgnored var pageFrame: CGRect = .zero
  private(set) var isDeparting = false
  @ObservationIgnored private var heldSession: ObjectIdentifier?

  func hold(_ controller: SessionController) {
    let session = ObjectIdentifier(controller)
    if let heldSession, heldSession != session {
      TranscriptSendStaging.shared.removeLandingProvider(for: heldSession, owner: self)
    }
    heldSession = session
    isDeparting = false
    let awaitsFirstSend = { [weak controller] in controller?.hasAcceptedFirstSend == false }
    TranscriptSendStaging.shared.setLandingProvider(
      for: session,
      owner: self,
      holds: { [weak self] in self?.heldSession == session && awaitsFirstSend() },
      landing: { [weak self] in awaitsFirstSend() ? self?.landing : nil },
      depart: { [weak self] in self?.isDeparting = true }
    )
  }

  func holds(_ session: ObjectIdentifier) -> Bool {
    heldSession == session
  }

  func release(_ session: ObjectIdentifier) {
    if heldSession == session { heldSession = nil }
    TranscriptSendStaging.shared.releaseHeldSend(session: session)
    TranscriptSendStaging.shared.removeLandingProvider(for: session, owner: self)
  }

  func returnSend(_ session: ObjectIdentifier) {
    TranscriptSendStaging.shared.cancel(session: session, animated: true)
    isDeparting = false
  }

  var landing: TranscriptSendLanding? {
    guard pageFrame.width > 0 else { return nil }
    let padding = VirtualizedTranscriptScrollView.horizontalPadding
    let rowWidth = min(VirtualizedTranscriptScrollView.maxRowWidth, max(1, pageFrame.width - padding * 2))
    let rowX = max(padding, (pageFrame.width - rowWidth) / 2)
    return TranscriptSendLanding(
      trailing: pageFrame.minX + rowX + rowWidth,
      top: pageFrame.minY + VirtualizedTranscriptScrollView.topPadding,
      maxBubbleWidth: rowWidth - 40
    )
  }
}
