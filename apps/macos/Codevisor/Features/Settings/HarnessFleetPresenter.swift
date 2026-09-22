import CodevisorCore
import CodevisorUI
import SwiftUI

/// One machine-bound sign-in or account manager, as a sheet item.
struct HarnessMachineSignInTarget: Identifiable {
  let machineId: String
  let harnessId: String
  let startsSignIn: Bool
  var id: String { "\(machineId)|\(harnessId)" }
}

/// The fleet-shared accounts sheet for one harness, with the machine the
/// caller was looking at (a chat's server) as the preferred sign-in host.
struct HarnessFleetAccountsTarget {
  let setting: HarnessFleet.Setting
  let preferredMachineId: String?
}

/// The sheets the shared harness list presents — fleet-shared accounts,
/// one machine's sign-in, the custom harness editor — owned by whichever
/// screen embeds the list (Settings › Harnesses, onboarding) so both
/// behave identically.
@MainActor @Observable
final class HarnessFleetPresenter {
  var accountsSetting: HarnessAccountsPresentation<HarnessFleetAccountsTarget>?
  var signInTarget: HarnessMachineSignInTarget?
  var editingCustomId: String?
  var showsCustomEditor = false

  func showAccounts(_ setting: HarnessFleet.Setting, startsSignIn: Bool, preferredMachineId: String? = nil) {
    accountsSetting = .init(
      HarnessFleetAccountsTarget(setting: setting, preferredMachineId: preferredMachineId),
      startsSignIn: startsSignIn)
  }

  func showSignIn(machineId: String, harnessId: String, startsSignIn: Bool) {
    signInTarget = .init(machineId: machineId, harnessId: harnessId, startsSignIn: startsSignIn)
  }

  /// The one entry for "open this harness's accounts": callers that only
  /// know a harness and the machine they were on (a rate-limited chat, a
  /// deep link) land on the fleet sheet when accounts are fleet-shared and
  /// on the machine's sheet only when they truly live there.
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

  func editCustom(_ setting: HarnessFleet.Setting) {
    editingCustomId = setting.id
    showsCustomEditor = true
  }
}

extension View {
  /// Attaches the harness list's sheets; `model` reloads its catalog after
  /// a custom harness is edited.
  func harnessFleetSheets(_ presenter: HarnessFleetPresenter, model: HarnessGlobalModel) -> some View {
    modifier(HarnessFleetSheetsModifier(presenter: presenter, model: model))
  }
}

private struct HarnessFleetSheetsModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Bindable var presenter: HarnessFleetPresenter
  let model: HarnessGlobalModel

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
      .sheet(isPresented: $presenter.showsCustomEditor) {
        CustomHarnessEditorSheet(editingId: presenter.editingCustomId) { _ in
          Task { await model.loadCatalog(in: environment) }
        }
        .environment(\.settingsMachineId, CodevisorMachine.local.id)
      }
  }
}
