import CodevisorCore
import CodevisorUI
import SwiftUI

/// The shared harness list: one row per harness, then one per machine.
struct HarnessesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Bindable private var settingsRouter = SettingsRouter.shared
  @State private var globalModel = HarnessGlobalModel()
  @State private var presenter = HarnessFleetPresenter()

  var body: some View {
    Form {
      HarnessGlobalSection(
        model: globalModel,
        onAccounts: { presenter.showAccounts($0, startsSignIn: $1) },
        onSignIn: { presenter.showSignIn(machineId: $0, harnessId: $1, startsSignIn: $2) },
        onEditCustom: { presenter.editCustom($0) }
      ) { id, symbol in
        HarnessIcon(harnessId: id, fallbackSymbolName: symbol, size: 18)
      }
    }
    .settingsPaneFormStyle(theme)
    .harnessFleetSheets(presenter, model: globalModel)
    .onChange(of: settingsRouter.pendingHarnessAccountRequest, initial: true) { _, request in
      // A chat's auth error deep-links to one harness on one machine.
      guard let request else { return }
      presenter.showSignIn(machineId: request.machineId, harnessId: request.harnessId, startsSignIn: false)
      settingsRouter.pendingHarnessAccountRequest = nil
    }
    .background {
      if !theme.isSystem { theme.windowBackground }
    }
  }
}

#Preview("Harnesses") {
  HarnessesSettingsView()
    .environment(AppEnvironment.preview())
    .frame(width: 520, height: 420)
}
