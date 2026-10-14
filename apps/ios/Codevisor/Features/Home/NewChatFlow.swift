import CodevisorUI
import SwiftUI
import UIKit

@MainActor @Observable
final class NewChatFlow: Identifiable {
  let id = UUID()
  let zoomsFromComposeButton: Bool
  var composerFocusRequest: UUID? = UUID()

  init(zoomsFromComposeButton: Bool) {
    self.zoomsFromComposeButton = zoomsFromComposeButton
  }
  var sessionId: UUID?
  var requestedServerId: String?
  var phase = NewChatPromotionPhase.composing
  var isWorkspaceReady = false
  var didPushCanonicalRoute = false
  var hasStartedExpansion = false
  var didStartFirstSendAnimation = false
  var didFinishFirstSendAnimation = false
  var didFinishSurfaceAnimation = false
  var promotionServerId: String?
  var promotionWorkspaceId: UUID?
  var promotionNavigationTitle: WorkspaceNavigationTitle?
  var presentationSession: NewChatPresentationSession?
  @ObservationIgnored var promotionSurface: NewChatPromotionSurface?
  @ObservationIgnored let promotionWatchdog = NewChatPromotionWatchdog()

  var isPromoting: Bool { phase == .animating || phase == .committing }
  func consumeFocusRequest(_ request: UUID) {
    guard composerFocusRequest == request else { return }
    composerFocusRequest = nil
  }
}
