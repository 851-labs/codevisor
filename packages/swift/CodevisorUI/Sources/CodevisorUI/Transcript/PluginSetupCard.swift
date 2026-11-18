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
      Button(action: performPrimaryAction) {
        PluginSetupCardLabel(title: title, isConnected: isConnected, icon: icon)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .modifier(TranscriptInlineCardSurface(inBotConversation: inBotConversation))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canAct && !isConnected)
      .allowsHitTesting(!isConnected)
      .help(request.reason)
      Spacer(minLength: inBotConversation ? TranscriptBubbleMetrics.oppositeSideGap : 0)
    }
  }

  private var name: String { request.name }

  private var canAct: Bool {
    !isConnected && model.canAct && !model.isWorking
  }

  private var title: String {
    if isConnected { return request.auth == .none ? "Installed \(name)" : "Connected with \(name)" }
    if model.step == .unavailable { return "\(name) isn’t available" }
    return model.connectsAccount ? "Connect with \(name)" : "Install \(name)"
  }

  private func performPrimaryAction() {
    guard canAct else { return }
    Task { await model.performPrimaryAction() }
  }
}

private struct PluginSetupCardLabel: View {
  let title: String
  let isConnected: Bool
  let icon: AnyView

  var body: some View {
    HStack(spacing: 8) {
      icon
      Text(title)
        .font(.callout.weight(.medium))
        .lineLimit(1)
      Image(systemName: isConnected ? "checkmark" : "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }
}
