import CodevisorCore
import SwiftUI

/// Native Form sections shared by the iPhone account page and Mac Account tab.
public struct CloudAccountSections: View {
  private let cloud: CloudAccountController
  private let manageConnections: () -> Void
  private let configureServer: () -> Void
  @State private var isSigningIn = false
  @State private var isDeleting = false
  @State private var showsDeleteConfirmation = false
  @State private var errorMessage: String?

  public init(
    cloud: CloudAccountController,
    manageConnections: @escaping () -> Void,
    configureServer: @escaping () -> Void
  ) {
    self.cloud = cloud
    self.manageConnections = manageConnections
    self.configureServer = configureServer
  }

  public var body: some View {
    Group {
      switch cloud.state {
      case .signedOut:
        CloudAccountAuthenticationSections(cloud: cloud, isSigningIn: $isSigningIn)
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
        if cloud.state.isSignedIn {
          Section {
            deleteAccountButton
          } footer: {
            deletionExplanation
          }
        }
      #endif
    }
    .confirmationDialog("Delete Cloud Account?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
      Button("Delete Cloud Account", role: .destructive) {
        isDeleting = true
        Task {
          await cloud.deleteAccount()
          isDeleting = false
          errorMessage = cloud.lastError
        }
      }
    } message: {
      Text("This permanently deletes your Cloud account and disconnects all your machines. This cannot be undone.")
    }
    .alert("Account", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
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
          deleteAccountButton
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

  private var deleteAccountButton: some View {
    Button(isDeleting ? "Deleting Account…" : "Delete Cloud Account", role: .destructive) {
      showsDeleteConfirmation = true
    }
    .foregroundStyle(.red)
    .disabled(isDeleting)
  }

  private var deletionExplanation: some View {
    Text(
      "Permanently delete your Cloud account and disconnect its machines. Files and chats on your machines are kept."
    )
  }
}
