import CodevisorCore
import SwiftUI

/// Native Form sections shared by the iPhone account page and Mac Account tab.
public struct CloudAccountSections: View {
  private let cloud: CloudAccountController
  private let manageConnections: () -> Void
  private let configureServer: () -> Void
  private let signInWithEmail: () -> Void
  @State private var isSigningIn = false
  @State private var isDeleting = false

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
          Button(action: manageConnections) {
            HStack {
              Label("Connected Accounts", systemImage: "person.crop.circle.badge.checkmark")
              Spacer()
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
          }
          .buttonStyle(.plain)
          .disabled(isDeleting)
        }
        Button(action: configureServer) {
          HStack {
            Label("Cloud Server", systemImage: "network")
            Spacer()
            Text(cloud.customServerURL == nil ? "Default" : "Custom")
              .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn || isDeleting)
      }
      #if os(iOS)
        CloudAccountDeletionSection(cloud: cloud, isDeleting: $isDeleting)
      #endif
    }
  }

  private func accountSection(_ email: String?) -> some View {
    Section {
      HStack(spacing: 12) {
        Image(systemName: "person.crop.circle.fill")
          .font(.system(size: 40))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Codevisor Cloud").font(.headline)
          Text(email ?? "Signed in")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(.vertical, 4)
      #if os(iOS)
        signOutButton
      #endif
    } footer: {
      #if os(macOS)
        HStack(spacing: 8) {
          signOutButton
          CloudAccountDeletionButton(cloud: cloud, isDeleting: $isDeleting)
          Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.body)
      #endif
    }
  }

  private var signOutButton: some View {
    Button("Sign Out") { cloud.signOut() }
      .disabled(isDeleting)
  }
}
