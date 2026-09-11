import CodevisorCore
import SwiftUI

struct CloudAccountAuthenticationSections: View {
  let cloud: CloudAccountController
  var link = false
  @Binding var isSigningIn: Bool
  @State private var authentication = CloudAuthenticationCoordinator()
  @State private var isLoadingProviders = true
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if link {
        connectionsSections
      } else {
        Section {
          providerButtons
        } header: {
          Text("Codevisor Cloud")
        } footer: {
          Text("Sign in to connect to your machines from anywhere.")
        }
      }
    }
    .task(id: cloud.state.isSignedIn) {
      guard link, cloud.state.isSignedIn else { return }
      await loadProviders()
    }
    .onChange(of: cloud.lastError) { _, message in
      if let message { errorMessage = message }
    }
    .alert("Account", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  @ViewBuilder
  private var connectionsSections: some View {
    if let linked = cloud.linkedProviders {
      if !linked.isEmpty {
        Section("Connected Accounts") {
          ForEach(CloudSignInProvider.allCases.filter { linked.contains($0) }, id: \.self) { provider in
            HStack(spacing: 12) {
              providerIcon(provider)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
              Text(provider == .github ? "GitHub" : "Apple")
              Spacer()
              Label("Connected", systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if hasUnlinkedProvider(linked) {
        Section {
          providerButtons
        } header: {
          Text("Connect Accounts")
        } footer: {
          Text("Use a connected account to sign in to this same Codevisor account.")
        }
      } else if linked.isEmpty {
        Section {
          Text("No connected accounts.").foregroundStyle(.secondary)
        }
      }
    } else {
      Section("Connected Accounts") {
        if isLoadingProviders {
          ProgressView("Loading accounts…")
        } else {
          Button("Try Again") { Task { await loadProviders() } }
        }
      }
    }
  }

  private func hasUnlinkedProvider(_ linked: Set<CloudSignInProvider>) -> Bool {
    (cloud.supportsGitHubSignIn && !linked.contains(.github))
      || (cloud.supportsAppleSignIn && !linked.contains(.apple))
  }

  @ViewBuilder
  private func providerIcon(_ provider: CloudSignInProvider) -> some View {
    if provider == .github {
      Image("GitHubMark").renderingMode(.template).resizable().scaledToFit()
    } else {
      Image(systemName: "apple.logo").font(.system(size: 20))
    }
  }

  private var providerButtons: some View {
    VStack(spacing: 12) {
      if cloud.supportsGitHubSignIn && (!link || cloud.linkedProviders?.contains(.github) == false) {
        CloudSignInProviderButton(title: "Sign in with GitHub", icon: .asset("GitHubMark")) {
          start(.github)
        }
      }
      if cloud.supportsAppleSignIn && (!link || cloud.linkedProviders?.contains(.apple) == false) {
        CloudAppleSignInButton { start(.apple) }
      }
      if !link && cloud.developmentAccountAvailable {
        CloudSignInProviderButton(title: "Use Development Account", icon: .system("hammer")) {
          Task { await cloud.signInWithDevelopmentAccount() }
        }
      }
      if isSigningIn { ProgressView() }
    }
    .padding(.vertical, 4)
    .disabled(isSigningIn)
  }

  private func start(_ provider: CloudSignInProvider) {
    isSigningIn = true
    Task {
      await authentication.signIn(provider: provider, cloud: cloud, link: link)
      isSigningIn = false
    }
  }

  private func loadProviders() async {
    isLoadingProviders = true
    await cloud.refreshLinkedProviders()
    isLoadingProviders = false
  }
}
