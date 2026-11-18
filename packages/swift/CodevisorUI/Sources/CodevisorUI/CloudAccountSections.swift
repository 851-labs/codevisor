import CodevisorCore
import SwiftUI

public struct CloudAccountSections<PageLink: View>: View {
  private let cloud: CloudAccountController
  private let signInWithEmail: () -> Void
  private let pageLink: (CloudAccountPage) -> PageLink
  @State private var isSigningIn = false

  public init(
    cloud: CloudAccountController,
    signInWithEmail: @escaping () -> Void,
    @ViewBuilder pageLink: @escaping (CloudAccountPage) -> PageLink
  ) {
    self.cloud = cloud
    self.signInWithEmail = signInWithEmail
    self.pageLink = pageLink
  }

  public var body: some View {
    Group {
      switch cloud.state {
      case .signedOut:
        CloudAccountAuthenticationSections(cloud: cloud, isSigningIn: $isSigningIn, signInWithEmail: signInWithEmail)
      case .validating:
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Signing in…").foregroundStyle(.secondary)
          }
        }
      case let .signedIn(email):
        accountSection(email)
      }
      Section {
        if cloud.state.isSignedIn {
          pageLink(.connectedAccounts)
            .disabled(cloud.isDeletingAccount)
        }
        pageLink(.server)
          .disabled(isSigningIn || cloud.isDeletingAccount)
      }
      CloudAccountDeletionSection(cloud: cloud)
    }
  }

  private func accountSection(_ email: String?) -> some View {
    Section {
      #if os(macOS)
        CloudAccountRow(subtitle: email ?? "Signed in") { signOutButton }
      #else
        CloudAccountRow(subtitle: email ?? "Signed in")
        signOutButton
      #endif
    }
  }

  private var signOutButton: some View {
    Button("Sign Out") { cloud.signOut() }
      .disabled(cloud.isDeletingAccount)
  }
}
