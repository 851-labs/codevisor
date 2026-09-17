import CodevisorCore
import CodevisorUI
import SwiftUI

struct PiProviderAuthenticationScreen: View {
  let serverId: String
  let harness: ServerHarness
  var onAuthenticated: () -> Void = {}
  var signInRequest: HarnessMachineSignIn?

  var body: some View {
    PiProviderAccounts(machineId: serverId, harness: harness, request: signInRequest) { updated in
      if harness.auth?.isSatisfied != true, updated.auth?.isSatisfied == true { onAuthenticated() }
    }
  }
}
