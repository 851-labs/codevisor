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
    TranscriptInlineCard(
      title: copy.headline,
      state: state,
      inBotConversation: inBotConversation
    )
  }

  private var copy: SetupRequestCopy {
    SetupRequestCopy(request: request, handoffMachineName: handoffMachineName, machineName: machineName)
  }

  private var state: TranscriptInlineCard.State {
    switch request.state {
    case .pending: .pending(message: copy.detail, actions: actions)
    case .setUp: .resolved(.completed("Set up"))
    case .declined: .resolved(.declined("Declined"))
    }
  }

  private var actions: [TranscriptInlineCard.Action] {
    let decline = TranscriptInlineCard.Action("Not Now", emphasis: .quiet, perform: onDecline)
    guard copy.canSetUpHere else { return [decline] }
    return [decline, TranscriptInlineCard.Action(copy.setUpTitle, emphasis: .primary, perform: onSetUp)]
  }
}
