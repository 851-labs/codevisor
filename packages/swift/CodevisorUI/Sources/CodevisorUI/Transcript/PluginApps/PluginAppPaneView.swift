import CodevisorCore
import SwiftUI

public struct PluginAppPaneView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.pluginAppPresenter) private var presenter
  private let model: PluginAppPaneModel

  public init(model: PluginAppPaneModel) {
    self.model = model
  }

  public var body: some View {
    let restriction = self.restriction
    VStack(spacing: 0) {
      PluginAppPaneHeader(model: model, isRestricted: restriction != nil, onBack: back)
      Divider()
      content(restriction: restriction)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .environment(model.environment)
    .task { await prepare() }
    .onChange(of: loadRequest(restriction: restriction), initial: true) { _, request in apply(request) }
  }

  @ViewBuilder
  private func content(restriction: String?) -> some View {
    if PluginAppSubjectPlaceholder.isBlocking(model.lookup.state, restriction: restriction) {
      PluginAppSubjectPlaceholder(state: model.lookup.state, restriction: restriction, onRetry: model.retry)
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    } else {
      PluginAppPageView(page: model.page, onRetry: model.retry)
    }
  }

  private var access: PluginAccessController { model.environment.pluginAccess }

  private var restriction: String? {
    model.subject.flatMap(access.restriction(for:))
  }

  private func loadRequest(restriction: String?) -> PluginAppLoadRequest {
    PluginAppLoadRequest(
      hasSubject: model.subject != nil, restriction: restriction,
      display: PluginAppDisplay(
        isDark: colorScheme == .dark, platform: PluginAppDisplay.currentPlatform,
        locale: PluginAppDisplay.currentLocale, mode: .fullscreen))
  }

  private func prepare() async {
    model.onBack = model.onBack ?? { [presenter, paneId = model.paneId] in presenter?.close(paneId) }
    model.appear()
    guard PluginAccessController.enforcesAgeGateOnThisPlatform, access.policy == nil else { return }

    try? await access.refresh()
  }

  private func apply(_ request: PluginAppLoadRequest) {
    guard request.hasSubject else { return }
    guard request.showsPage else {
      model.suspend()
      return
    }

    model.show(display: request.display)
  }

  private func back() {
    model.onBack?()
  }
}
