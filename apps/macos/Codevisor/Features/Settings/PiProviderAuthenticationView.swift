import CodevisorCore
import CodevisorUI
import SwiftUI

struct PiProviderAuthenticationView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.settingsMachineId) private var settingsMachineId
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  let harness: ServerHarness
  var onChange: (ServerHarness) -> Void
  var showsHeader = true
  var signInRequest: HarnessMachineSignIn?
  @State private var workingLabel: String?

  private var machineId: String { settingsMachineId ?? environment.defaultComposerServerId }

  var body: some View {
    if showsHeader {
      NavigationStack { accounts.navigationTitle("Pi Accounts") }
        .onPreferenceChange(HarnessAccountsWorkingPreference.self) { workingLabel = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter(status: workingLabel) {
            Button("Done") { dismiss() }
              .settingsActionTint(theme)
              .keyboardShortcut(.defaultAction)
              .disabled(workingLabel != nil)
          }
        }
        .sheetSize(.list)
        .themedSurface(.sheet)
    } else {
      accounts
    }
  }

  private var accounts: some View {
    HarnessProviderAccountsView(harness: harness, machineId: machineId, request: signInRequest) {
      guard !isShared,
        let updated = try? await environment.refreshHarnessAuthentication(harnessId: harness.id, onServer: machineId)
      else { return }
      onChange(updated)
    }
  }
}
