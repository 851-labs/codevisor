import CodevisorUI
import SwiftUI
import UIKit

/// State shared across the native New Chat sheet and the workspace mounted
/// beneath it during first-send promotion. Keeping the durable controller in
/// `ChatControllerCache` and the handoff state here means neither presentation
/// container has to masquerade as the other.
@MainActor @Observable
final class NewChatFlow: Identifiable {
  let id = UUID()
  var composerFocusRequest: UUID? = UUID()
  var sessionId: UUID?
  var phase = NewChatPromotionPhase.composing
  var isWorkspaceReady = false
  var didPushCanonicalRoute = false
  /// The replica shows the compose sheet's chrome until the expansion
  /// begins, then morphs it into the route's in place.
  var hasStartedExpansion = false
  var didStartFirstSendAnimation = false
  var didFinishFirstSendAnimation = false
  var didFinishSurfaceAnimation = false
  var promotionServerId: String?
  var promotionWorkspaceId: UUID?
  var presentationSession: NewChatPresentationSession?
  @ObservationIgnored var homeSnapshot: UIImage?
  @ObservationIgnored var promotionSurface: NewChatPromotionSurface?
  @ObservationIgnored let promotionWatchdog = NewChatPromotionWatchdog()

  var isPromoting: Bool { phase == .animating || phase == .committing }
  func consumeFocusRequest(_ request: UUID) {
    guard composerFocusRequest == request else { return }
    composerFocusRequest = nil
  }
}
