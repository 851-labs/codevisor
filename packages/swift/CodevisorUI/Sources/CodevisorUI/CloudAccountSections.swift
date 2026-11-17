import CodevisorCore
import SwiftUI

public struct CloudAccountSections: View {
  private let cloud: CloudAccountController
  private let manageConnections: () -> Void
  private let configureServer: () -> Void
  private let signInWithEmail: () -> Void
  @State private var isSigningIn = false

  public init(
    cloud: CloudAccountController,
    manageConnections: @escaping () -> Void,
    configureServer: @escaping () -> Void,
    signInWithEmail: @escaping () -> Void
  ) {
    self.cloud = cloud
    self.manageConnections = manageConnections
    self.configureServer = configureServer
    self.signInWithEmail = signInWithEmail
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
          SettingsNavigationRow(
            "Connected Accounts",
            systemImage: "person.crop.circle.badge.checkmark",
            action: manageConnections
          )
          .disabled(cloud.isDeletingAccount)
        }
        SettingsNavigationRow(title: "Cloud Server", systemImage: "network", action: configureServer) {
          Text(cloud.customServerURL == nil ? "Default" : "Custom")
            .foregroundStyle(.secondary)
        }
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
