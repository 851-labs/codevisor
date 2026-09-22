import CodevisorCore
import SwiftUI

/// The SwiftUI-side navigation expectations the diagnostics probe checks
/// against UIKit. Split from `WorkspaceScreen` for the size ratchet.
extension WorkspaceScreen {
  var navigationDiagnosticState: IOSNavigationDiagnosticState {
    let identifier = workspaceId ?? activeSessionId ?? draftPlaceholderId
    let contentPhase: String
    if blocksServerContent {
      contentPhase = "server-blocked"
    } else if isDraft {
      contentPhase = draftController == nil ? "draft-missing" : "draft-ready"
    } else if let pane = activePane, pane.kind == .chat {
      if let controller = chatController(for: pane) {
        if controller.model != nil {
          contentPhase = "model-ready"
        } else if controller.isConnecting {
          contentPhase = "connecting"
        } else if controller.isLoadingInitialHistory {
          contentPhase = "history-loading-idle"
        } else {
          contentPhase = "model-missing-idle"
        }
      } else {
        contentPhase = "controller-missing"
      }
    } else {
      contentPhase = "non-chat"
    }
    // A split detail has no back button and a depth of one; only the
    // compact stack owns a native back.
    let hostedInSplitDetail = homeLayoutMode == .split && !isNewChatPresentation
    return IOSNavigationDiagnosticState(
      screen: "workspace",
      identifier: String(identifier.uuidString.prefix(8)),
      isNewChatPresentation: isNewChatPresentation,
      hasStarted: presentsAsStarted,
      isDraft: isDraft,
      blocksServerContent: blocksServerContent,
      expectsNativeBack: !isNewChatPresentation && !hostedInSplitDetail,
      hostedInSplitDetail: hostedInSplitDetail,
      expectsLeadingButton: false,
      expectsTrailingButton: isNewChatPresentation
        || (!blocksServerContent && !isDraft),
      contentPhase: contentPhase
    )
  }
}
