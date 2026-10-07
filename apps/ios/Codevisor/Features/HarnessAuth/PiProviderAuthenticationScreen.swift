import CodevisorCore
import CodevisorUI
import SwiftUI

struct PiProviderAuthenticationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.sharedHarnessAccounts) private var isShared
  let serverId: String
  let harness: ServerHarness
  var onAuthenticated: () -> Void = {}
  var signInRequest: HarnessMachineSignIn?

  var body: some View {
    HarnessProviderAccountsView(harness: harness, machineId: serverId, request: signInRequest) {
      guard !isShared,
        let updated = try? await environment.refreshHarnessAuthentication(harnessId: harness.id, onServer: serverId)
      else { return }
      if harness.auth?.isSatisfied != true, updated.auth?.isSatisfied == true { onAuthenticated() }
    }
    .toolbar { HarnessAccountsCloseToolbar() }
  }
}
