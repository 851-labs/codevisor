import CodevisorCore
import SwiftUI

public struct PluginSetupCard: View {
  let model: PluginSetupModel
  let request: ServerPluginSetupRequest
  let isConnected: Bool
  let inBotConversation: Bool
  let icon: AnyView

  public init(
    model: PluginSetupModel,
    request: ServerPluginSetupRequest,
    isConnected: Bool,
    inBotConversation: Bool,
    icon: AnyView
  ) {
    self.model = model
    self.request = request
    self.isConnected = isConnected
    self.inBotConversation = inBotConversation
    self.icon = icon
  }

  public var body: some View {
    HStack(spacing: 0) {
      HStack(alignment: .center, spacing: TranscriptInlineCardMetrics.iconSpacing) {
        icon
        TranscriptInlineCardText(title: request.name, message: summary)
        Spacer(minLength: 8)
        PluginSetupCardAccessory(state: accessory, perform: performPrimaryAction)
      }
      .padding(ComposerCardStyle.contentPadding)
      .modifier(TranscriptInlineCardSurface(inBotConversation: inBotConversation))
      .frame(maxWidth: TranscriptInlineCardMetrics.maxWidth, alignment: .leading)
      Spacer(minLength: inBotConversation ? TranscriptBubbleMetrics.oppositeSideGap : 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(request.name)
  }

  private var summary: String {
    request.description.flatMap(Self.firstSentence) ?? request.reason
  }

  private static func firstSentence(of text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let end = trimmed.range(of: ". ") else { return trimmed }
    return String(trimmed[..<end.lowerBound]) + "."
  }

  private var accessory: PluginSetupCardAccessory.State {
    if isConnected { return .done(request.auth == .none ? "Installed" : "Connected") }
    if model.isWorking { return .working }
    if model.step == .unavailable { return .unavailable }
    return .action("Connect", isEnabled: model.canAct)
  }

  private func performPrimaryAction() {
    guard !isConnected, model.canAct, !model.isWorking else { return }
    Task { await model.performPrimaryAction() }
  }
}
