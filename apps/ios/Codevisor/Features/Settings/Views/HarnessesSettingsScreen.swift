import CodevisorCore
import CodevisorUI
import SwiftUI

struct HarnessesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var globalModel = HarnessGlobalModel()
  @State private var accountsSetting: HarnessAccountsPresentation<HarnessFleet.Setting>?
  @State private var pendingSignIn: HarnessSignInRequest?

  var body: some View {
    List {
      HarnessGlobalSection(
        model: globalModel,
        onAccounts: { setting, signIn in
          accountsSetting = .init(setting, startsSignIn: signIn)
        },
        onSignIn: { machineId, harnessId, startsSignIn in
          pendingSignIn = HarnessSignInRequest(serverId: machineId, harnessId: harnessId, startsSignIn: startsSignIn)
        }
      ) { id, symbol in
        HarnessIconView(harnessId: id, fallbackSymbolName: symbol, size: 22)
      }
    }
    .navigationTitle("Harnesses")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $accountsSetting) { presentation in
      let setting = presentation.selection
      HarnessAccountsSheet(harnessId: setting.id, harnessName: setting.name, startsSignIn: presentation.startsSignIn) {
        machineId, harness, request in
        HarnessAuthenticationScreen(serverId: machineId ?? "", harness: harness, signInRequest: request)
      }
    }
    .harnessSignInSheet(request: $pendingSignIn)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        HarnessAddButton(model: globalModel) { id, symbol in
          HarnessIconView(harnessId: id, fallbackSymbolName: symbol, size: 22)
        }
        .labelStyle(.iconOnly)
      }
    }
  }
}
