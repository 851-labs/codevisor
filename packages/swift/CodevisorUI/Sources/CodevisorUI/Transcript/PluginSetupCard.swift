import CodevisorCore
import SwiftUI

public struct PluginSetupCard: View {
  let model: PluginSetupModel
  let resolution: PluginSetupResolution?
  let inBotConversation: Bool
  let icon: AnyView
  let onDecline: () -> Void

  public init(
    model: PluginSetupModel,
    resolution: PluginSetupResolution?,
    inBotConversation: Bool,
    icon: AnyView,
    onDecline: @escaping () -> Void
  ) {
    self.model = model
    self.resolution = resolution
    self.inBotConversation = inBotConversation
    self.icon = icon
    self.onDecline = onDecline
  }

  public var body: some View {
    TranscriptInlineCard(
      title: model.request.name,
      state: state,
      inBotConversation: inBotConversation,
      tone: model.errorMessage == nil ? .neutral : .error,
      leadingIconView: isResolved ? nil : icon
    )
  }

  private var isResolved: Bool {
    resolution != nil || model.step == .ready
  }

  private var summary: String {
    if let description = model.request.description.flatMap(Self.firstSentence) { return description }
    return model.step == .install ? "Install it to use it in this chat." : "Sign in to use it in this chat."
  }

  private static func firstSentence(of text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let end = trimmed.range(of: ". ") else { return trimmed }
    return String(trimmed[..<end.lowerBound]) + "."
  }

  private var state: TranscriptInlineCard.State {
    if resolution == .declined { return .resolved(.declined("Declined")) }
    if resolution == .connected || model.step == .ready { return .resolved(.completed("Connected")) }
    return .pending(message: model.errorMessage ?? summary, actions: actions)
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
