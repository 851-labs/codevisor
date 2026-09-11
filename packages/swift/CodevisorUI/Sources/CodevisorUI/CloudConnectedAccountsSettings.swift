import CodevisorCore
import SwiftUI

public struct CloudConnectedAccountsSettings: View {
  private let cloud: CloudAccountController
  @Environment(\.dismiss) private var dismiss
  @State private var isSigningIn = false

  public init(cloud: CloudAccountController) { self.cloud = cloud }

  public var body: some View {
    Form {
      CloudAccountAuthenticationSections(cloud: cloud, link: true, isSigningIn: $isSigningIn)
    }
    .formStyle(.grouped)
    .navigationTitle("Connected Accounts")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .interactiveDismissDisabled(isSigningIn)
    .onChange(of: cloud.state.isSignedIn) { _, signedIn in
      if !signedIn { dismiss() }
    }
  }
}
