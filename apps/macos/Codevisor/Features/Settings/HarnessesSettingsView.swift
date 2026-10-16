import CodevisorCore
import CodevisorUI
import SwiftUI

struct HarnessesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
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
    .formStyle(.grouped)
    .harnessFleetSheets(presenter) { settingsRouter.pendingHarnessAccountRequest = nil }
    .onChange(of: settingsRouter.pendingHarnessAccountRequest, initial: true) { _, request in
      guard let request else { return }
      presenter.present(
        harnessId: request.harnessId, machineId: request.machineId, startsSignIn: false, in: environment)
    }
  }
}

#Preview("Harnesses") {
  HarnessesSettingsView()
    .environment(AppEnvironment.preview())
    .frame(width: 520, height: 420)
}
