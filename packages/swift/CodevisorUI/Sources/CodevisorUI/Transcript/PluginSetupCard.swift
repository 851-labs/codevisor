import CodevisorCore
import SwiftUI

public struct PluginSetupCard: View {
  let model: PluginSetupModel
  let resolution: PluginSetupResolution?
  let inBotConversation: Bool
  let onDecline: () -> Void

  public init(
    model: PluginSetupModel,
    resolution: PluginSetupResolution?,
    inBotConversation: Bool,
    onDecline: @escaping () -> Void
  ) {
    self.model = model
    self.resolution = resolution
    self.inBotConversation = inBotConversation
    self.onDecline = onDecline
  }

  public var body: some View {
    TranscriptInlineCard(
      title: model.request.name,
      state: state,
      inBotConversation: inBotConversation,
      tone: model.errorMessage == nil ? .neutral : .error,
      accessory: AnyView(PluginSetupCardDetail(request: model.request))
    )
  }

  private var state: TranscriptInlineCard.State {
    if resolution == .declined { return .resolved(.declined("Declined")) }
    if resolution == .connected || model.step == .ready { return .resolved(.completed("Set up")) }
    return .pending(message: model.errorMessage ?? model.request.reason, actions: actions)
  }

  private var actions: [TranscriptInlineCard.Action] {
    let decline = TranscriptInlineCard.Action(PluginSetupResolution.declineLabel, emphasis: .quiet, perform: onDecline)
    guard let title = model.actionTitle else { return [decline] }
    return [decline, TranscriptInlineCard.Action(title, emphasis: .primary, perform: performPrimaryAction)]
  }

  private func performPrimaryAction() {
    guard !model.isWorking else { return }
    Task { await model.performPrimaryAction() }
  }
}
