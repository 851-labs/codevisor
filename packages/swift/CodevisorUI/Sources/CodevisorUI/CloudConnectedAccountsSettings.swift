import CodevisorCore
import SwiftUI

struct CloudConnectedAccountsSettings: View {
  private let cloud: CloudAccountController
  @State private var isSigningIn = false

  init(cloud: CloudAccountController) { self.cloud = cloud }

  var body: some View {
    Form {
      CloudAccountAuthenticationSections(cloud: cloud, link: true, isSigningIn: $isSigningIn)
    }
    .formStyle(.grouped)
    .navigationTitle("Connected Accounts")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .interactiveDismissDisabled(isSigningIn)
  }
}
