import CodevisorCore
import CodevisorUI
import SwiftUI

struct HarnessMachineSignInTarget: Identifiable {
  let machineId: String
  let harnessId: String
  let startsSignIn: Bool
  var id: String { "\(machineId)|\(harnessId)" }
}

struct HarnessFleetAccountsTarget {
  let setting: HarnessFleet.Setting
  let preferredMachineId: String?
}

@MainActor @Observable
final class HarnessFleetPresenter {
  var accountsSetting: HarnessAccountsPresentation<HarnessFleetAccountsTarget>?
  var signInTarget: HarnessMachineSignInTarget?

  func showAccounts(_ setting: HarnessFleet.Setting, startsSignIn: Bool, preferredMachineId: String? = nil) {
    accountsSetting = .init(
      HarnessFleetAccountsTarget(setting: setting, preferredMachineId: preferredMachineId),
      startsSignIn: startsSignIn)
  }

  func showSignIn(machineId: String, harnessId: String, startsSignIn: Bool) {
    signInTarget = .init(machineId: machineId, harnessId: harnessId, startsSignIn: startsSignIn)
  }

  func present(
    harnessId: String, machineId: String, startsSignIn: Bool, in environment: AppEnvironment
  ) {
    guard HarnessRegistry.descriptor(for: harnessId).sharesFleetAccounts else {
      showSignIn(machineId: machineId, harnessId: harnessId, startsSignIn: startsSignIn)
      return
    }
    let setting =
      HarnessFleet.settings(environment.configSync).first { $0.id == harnessId }
      ?? HarnessFleet.Setting(
        id: harnessId, name: HarnessRegistry.displayName(for: harnessId),
        symbolName: HarnessRegistry.descriptor(for: harnessId).symbolName, enabled: true, installed: true)
    showAccounts(setting, startsSignIn: startsSignIn, preferredMachineId: machineId)
  }
}

extension View {
  func harnessFleetSheets(_ presenter: HarnessFleetPresenter) -> some View {
    modifier(HarnessFleetSheetsModifier(presenter: presenter))
  }
}

private struct HarnessFleetSheetsModifier: ViewModifier {
  @Bindable var presenter: HarnessFleetPresenter

  func body(content: Content) -> some View {
    content
      .sheet(item: $presenter.accountsSetting) { presentation in
        let setting = presentation.selection.setting
        HarnessAccountsSheet(
          harnessId: setting.id, harnessName: setting.name, startsSignIn: presentation.startsSignIn,
          preferredMachineId: presentation.selection.preferredMachineId
        ) { machineId, harness, request in
          HarnessAuthenticationView(
            harness: harness, onChange: { _ in },
            showsHeader: false,
            signInRequest: request
          )
          .environment(\.settingsMachineId, machineId)
        }
      }
      .sheet(item: $presenter.signInTarget) { target in
        HarnessSignInSheet(serverId: target.machineId, harnessId: target.harnessId, startsSignIn: target.startsSignIn)
      }
  }
}
