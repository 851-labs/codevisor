import CodevisorCore
import CodevisorUI
import SwiftUI

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
        onSignIn: { presenter.showSignIn(machineId: $0, harnessId: $1, startsSignIn: $2) }
      ) { id, symbol in
        HarnessIcon(harnessId: id, fallbackSymbolName: symbol, size: 18)
      }
    }
    .settingsPaneFormStyle(theme)
    .harnessFleetSheets(presenter)
    .onChange(of: settingsRouter.pendingHarnessAccountRequest, initial: true) { _, request in
      guard let request else { return }
      presenter.present(
        harnessId: request.harnessId, machineId: request.machineId, startsSignIn: false, in: environment)
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
