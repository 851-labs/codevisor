import CodevisorCore
import SwiftUI

struct PluginAppInlineView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  let model: PluginAppInlineModel
  let host: PluginAppHost

  var body: some View {
    let restriction = self.restriction
    VStack(alignment: .leading, spacing: 6) {
      PluginAppInlineHeader(model: model, isRestricted: restriction != nil)
      PluginAppInlineContent(model: model, restriction: restriction)
    }
    .environment(host.environment)
    .task { await prepare() }
    .onChange(of: loadRequest(restriction: restriction), initial: true) { _, request in apply(request) }
    .onChange(of: model.page.height) { _, _ in invalidateRowMeasurement?() }
    .onChange(of: model.page.phase) { _, _ in invalidateRowMeasurement?() }
    .onChange(of: model.mode) { _, _ in invalidateRowMeasurement?() }
  }

  private var access: PluginAccessController { host.environment.pluginAccess }

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
