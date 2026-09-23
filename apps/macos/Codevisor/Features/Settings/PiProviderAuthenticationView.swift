import CodevisorCore
import CodevisorUI
import SwiftUI

struct PiProviderAuthenticationView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.settingsMachineId) private var settingsMachineId
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  let harness: ServerHarness
  var onChange: (ServerHarness) -> Void
  var showsHeader = true
  var signInRequest: HarnessMachineSignIn?

  var body: some View {
    if showsHeader {
      NavigationStack { accounts.navigationTitle("Pi Accounts") }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter {
            Button("Done") { dismiss() }
              .settingsActionTint(theme)
              .keyboardShortcut(.defaultAction)
          }
        }
        .sheetSize(.list)
        .themedSurface(.sheet)
    } else {
      accounts
    }
  }
  private var accounts: some View {
    PiProviderAccounts(
      machineId: settingsMachineId ?? environment.defaultComposerServerId,
      harness: harness, request: signInRequest, onChange: onChange)
  }
}
