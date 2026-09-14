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
  var requestedServerId: String?
  var phase = NewChatPromotionPhase.composing
  var isWorkspaceReady = false
  var didPushCanonicalRoute = false
  /// The live sheet morphs its navigation controls as expansion begins.
  var hasStartedExpansion = false
  var didStartFirstSendAnimation = false
  var didFinishFirstSendAnimation = false
  var didFinishSurfaceAnimation = false
  var promotionServerId: String?
  var promotionWorkspaceId: UUID?
  var presentationSession: NewChatPresentationSession?
  @ObservationIgnored var promotionSurface: NewChatPromotionSurface?
  @ObservationIgnored let promotionWatchdog = NewChatPromotionWatchdog()

  var isPromoting: Bool { phase == .animating || phase == .committing }
  func consumeFocusRequest(_ request: UUID) {
    guard composerFocusRequest == request else { return }
    composerFocusRequest = nil
  }
}
