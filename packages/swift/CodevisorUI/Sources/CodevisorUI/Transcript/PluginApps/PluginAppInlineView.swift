import CodevisorCore
import SwiftUI

struct PluginAppInlineView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var confirmingBlock = false
  let model: PluginAppInlineModel
  let host: PluginAppHost

  var body: some View {
    let restriction = self.restriction
    PluginAppInlineContent(model: model, restriction: restriction)
      .environment(host.environment)
      .task { await prepare() }
      .task(id: model.subject) { model.page.contextActions = contextActions }
      .modifier(
        PluginAppInlineSafety(subject: model.subject, confirmingBlock: $confirmingBlock)
      )
      .onChange(of: loadRequest(restriction: restriction), initial: true) { _, request in apply(request) }
      .onChange(of: model.page.height) { _, _ in invalidateRowMeasurement?() }
      .onChange(of: model.page.phase) { _, _ in invalidateRowMeasurement?() }
      .onChange(of: model.mode) { _, _ in invalidateRowMeasurement?() }
  }

  private var access: PluginAccessController { host.environment.pluginAccess }

  private var contextActions: [PluginAppContextAction] {
    guard let subject = model.subject else { return [] }
    return [
      PluginAppContextAction(title: "Block \(subject.publisher)…", systemImage: "hand.raised") {
        confirmingBlock = true
      }
    ]
  }

  private var restriction: String? {
    model.subject.flatMap(access.restriction(for:))
  }

  private func loadRequest(restriction: String?) -> PluginAppLoadRequest {
    PluginAppLoadRequest(
      hasSubject: model.subject != nil, restriction: restriction,
      display: PluginAppDisplay(
        isDark: colorScheme == .dark, platform: PluginAppDisplay.currentPlatform,
        locale: PluginAppDisplay.currentLocale),
      showsElsewhere: model.mode == .fullscreen)
  }

  private func prepare() async {
    model.attach(host, chatSessionId: host.chatSessionId)
    guard PluginAccessController.enforcesAgeGateOnThisPlatform, access.policy == nil else { return }

    try? await access.refresh()
  }

  private func apply(_ request: PluginAppLoadRequest) {
    guard request.hasSubject else { return }
    guard request.showsPage else {
      model.page.suspend()
      return
    }

    model.show(display: request.display)
  }
}

private struct PluginAppInlineSafety: ViewModifier {
  let subject: PluginModerationSubject?
  @Binding var confirmingBlock: Bool

  func body(content: Content) -> some View {
    if let subject {
      content.pluginBlockConfirmation(subject: subject, isPresented: $confirmingBlock)
    } else {
      content
    }
  }
}
