import SwiftUI
import TranscriptKit

public struct TranscriptSetupRequestCard: View {
  let request: TranscriptSetupRequest
  let inBotConversation: Bool
  let handoffMachineName: String?
  let machineName: String?
  let onSetUp: () -> Void
  let onDecline: () -> Void

  public init(
    request: TranscriptSetupRequest,
    inBotConversation: Bool,
    handoffMachineName: String?,
    machineName: String? = nil,
    onSetUp: @escaping () -> Void,
    onDecline: @escaping () -> Void
  ) {
    self.request = request
    self.inBotConversation = inBotConversation
    self.handoffMachineName = handoffMachineName
    self.machineName = machineName
    self.onSetUp = onSetUp
    self.onDecline = onDecline
  }

  public var body: some View {
    HStack(spacing: 0) {
      Group {
        if copy.isPending {
          SetupRequestPendingContent(copy: copy, actions: actions)
        } else {
          SetupRequestResolvedRow(copy: copy)
        }
      }
      .padding(.horizontal, ComposerCardStyle.contentPadding)
      .padding(.vertical, verticalPadding)
      .modifier(SetupRequestCardSurface(inBotConversation: inBotConversation))
      .frame(maxWidth: SetupRequestCardMetrics.maxWidth, alignment: .leading)
      Spacer(minLength: inBotConversation ? SetupRequestCardMetrics.bubbleTrailingInset : 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(copy.isPending ? copy.title : copy.resolvedTitle)
  }

  private var copy: SetupRequestCopy {
    SetupRequestCopy(request: request, handoffMachineName: handoffMachineName, machineName: machineName)
  }

  private var actions: [ComposerNoticeCard.Action] {
    let decline = ComposerNoticeCard.Action("Not Now", emphasis: .quiet, perform: onDecline)
    guard copy.canSetUpHere else { return [decline] }
    return [decline, ComposerNoticeCard.Action(copy.setUpTitle, emphasis: .primary, perform: onSetUp)]
  }

  private var verticalPadding: CGFloat {
    if copy.isPending {
      ComposerCardStyle.contentPadding
    } else {
      SetupRequestCardMetrics.resolvedVerticalPadding
    }
  }
}
