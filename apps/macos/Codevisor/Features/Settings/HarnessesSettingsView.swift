import CodevisorCore
import CodevisorUI
import SwiftUI

/// One machine-bound sign-in or account manager, as a sheet item.
private struct HarnessMachineSignInTarget: Identifiable {
  let machineId: String
  let harnessId: String
  let startsSignIn: Bool
  var id: String { "\(machineId)|\(harnessId)" }
}

/// The shared harness list: one row per harness; machines live in its menu.
struct HarnessesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Bindable private var settingsRouter = SettingsRouter.shared
  @State private var globalModel = HarnessGlobalModel()
  @State private var accountsSetting: HarnessAccountsPresentation<HarnessFleet.Setting>?
  @State private var signInTarget: HarnessMachineSignInTarget?
  @State private var editingCustomId: String?
  @State private var showsCustomEditor = false

  var body: some View {
    Form {
      HarnessGlobalSection(
        model: globalModel,
        onAccounts: { setting, signIn in
          accountsSetting = .init(setting, startsSignIn: signIn)
        },
        onSignIn: { machineId, harnessId, startsSignIn in
          signInTarget = .init(machineId: machineId, harnessId: harnessId, startsSignIn: startsSignIn)
        },
        onEditCustom: { setting in
          editingCustomId = setting.id
          showsCustomEditor = true
        }
      ) { id, symbol in
        HarnessIcon(harnessId: id, fallbackSymbolName: symbol, size: 18)
      }
    }
    .settingsPaneFormStyle(theme)
    .sheet(item: $accountsSetting) { presentation in
      let setting = presentation.selection
      HarnessAccountsSheet(harnessId: setting.id, harnessName: setting.name, startsSignIn: presentation.startsSignIn) {
        machineId, harness, request in
        HarnessAuthenticationView(
          harness: harness, onChange: { _ in },
          showsHeader: false,
          signInRequest: request
        )
        .environment(\.settingsMachineId, machineId)
      }
    }
    .sheet(item: $signInTarget) { target in
      HarnessSignInSheet(serverId: target.machineId, harnessId: target.harnessId, startsSignIn: target.startsSignIn)
    }
    .sheet(isPresented: $showsCustomEditor) {
      CustomHarnessEditorSheet(editingId: editingCustomId) { _ in
        Task { await globalModel.loadCatalog(in: environment) }
      }
      .environment(\.settingsMachineId, CodevisorMachine.local.id)
    }
    .onChange(of: settingsRouter.pendingHarnessAccountRequest, initial: true) { _, request in
      // A chat's auth error deep-links to one harness on one machine.
      guard let request else { return }
      signInTarget = .init(machineId: request.machineId, harnessId: request.harnessId, startsSignIn: false)
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
