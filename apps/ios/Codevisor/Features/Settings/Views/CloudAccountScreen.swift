import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Account

/// Codevisor Cloud sign-in and self-hosted server configuration.
struct CloudAccountScreen: View {
  @Environment(AppEnvironment.self) private var environment

  @State private var signIn = CloudSignInCoordinator()
  @State private var isSigningIn = false
  @State private var serverURLText = ""
  @State private var serverError: String?
  @State private var isConnectingServer = false

  private var cloud: CloudAccountController { environment.cloud }

  var body: some View {
    List {
      switch cloud.state {
      case .signedOut:
        signedOutSection
      case .validating:
        validatingSection
      case let .signedIn(userEmail):
        signedInSection(userEmail: userEmail)
      }
      advancedSection
    }
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      serverURLText = cloud.customServerURL?.absoluteString ?? ""
    }
  }

  // MARK: Signed out

  private var signedOutSection: some View {
    Section {
      if cloud.supportsGitHubSignIn {
        Button {
          startSignIn()
        } label: {
          HStack {
            Text("Sign in with GitHub")
            if isSigningIn {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(isSigningIn)
      }
      if cloud.developmentAccountAvailable {
        Button("Use Development Account") {
          Task { await cloud.signInWithDevelopmentAccount() }
        }
        .disabled(isSigningIn)
      }
      if let lastError = cloud.lastError {
        Text(lastError)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Codevisor Cloud")
    } footer: {
      Text("See and connect to all of your machines from anywhere — end-to-end encrypted.")
    }
  }

  private var validatingSection: some View {
    Section {
      HStack(spacing: 8) {
        ProgressView()
        Text("Signing in…")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Codevisor Cloud")
    }
  }

  // MARK: Signed in

  private func signedInSection(userEmail: String?) -> some View {
    Section {
      HStack(spacing: 10) {
        Image(systemName: "person.crop.circle.badge.checkmark")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(userEmail ?? "Signed in")
            .fontWeight(.medium)
          Text(cloud.serverURL.host() ?? cloud.serverURL.absoluteString)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Button("Sign Out", role: .destructive) {
        cloud.signOut()
      }
      if let lastError = cloud.lastError {
        Text(lastError)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Account")
    }
  }

  // MARK: Advanced (self-hosted server)

  private var advancedSection: some View {
    Section {
      TextField("https://cloud.example.com", text: $serverURLText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
      Button(isConnectingServer ? "Connecting…" : "Connect") {
        connectCustomServer()
      }
      .disabled(isConnectingServer)
      if cloud.customServerURL != nil {
        Button("Use Default Server") {
          Task {
            try? await cloud.setCustomServer(nil)
            serverURLText = ""
            serverError = nil
          }
        }
      }
      if let serverError {
        Text(serverError)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Advanced")
    } footer: {
      Text(currentServerDescription)
    }
  }

  private var currentServerDescription: String {
    if let custom = cloud.customServerURL {
      if let instance = cloud.customInstanceName, !instance.isEmpty {
        return
          "Using self-hosted server “\(instance)” at \(custom.absoluteString). Connecting to a different server signs you out."
      }
      return "Using self-hosted server \(custom.absoluteString). Connecting to a different server signs you out."
    }
    return
      "Using the default Codevisor Cloud. Enter the URL of a self-hosted instance to use it instead — connecting signs you out of the current server."
  }

  private func connectCustomServer() {
    let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    serverError = nil
    guard !trimmed.isEmpty else {
      // An emptied field means "back to the default instance".
      Task {
        try? await cloud.setCustomServer(nil)
      }
      return
    }
    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: withScheme), url.host() != nil else {
      serverError = "“\(trimmed)” isn't a valid URL."
      return
    }
    isConnectingServer = true
    Task {
      defer { isConnectingServer = false }
      do {
        try await cloud.setCustomServer(url)
        serverURLText = url.absoluteString
      } catch {
        Log.cloud.error("Custom cloud server validation failed: \(String(describing: error), privacy: .public)")
        serverError = ErrorReporter.userFacingMessage(for: error)
      }
    }
  }

  // MARK: Sign-in flow

  private func startSignIn() {
    let scheme = CloudSignInCoordinator.callbackScheme
    isSigningIn = true
    cloud.lastError = nil
    signIn.start(
      url: cloud.signInURL(scheme: scheme),
      callbackScheme: scheme
    ) { callbackURL in
      isSigningIn = false
      guard let callbackURL,
        let deeplink = CloudAuthDeeplink.parse(callbackURL)
      else { return }
      Task { await cloud.completeSignIn(ott: deeplink.ott) }
    }
  }

}
