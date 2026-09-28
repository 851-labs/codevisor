import CodevisorCore
import CodevisorUI
import SwiftUI

/// "Authorize this machine?" — opened by scanning the QR code
/// `codevisor auth login` prints (a universal link to the cloud's `/device`
/// page). Signed out, it signs in first and then continues to the approval;
/// a link from any cloud other than the account's own is refused, so the
/// session token never leaves for another origin.
struct CloudDeviceApprovalSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let request: CloudDeviceApprovalRequest

  @State private var authentication = CloudAuthenticationCoordinator()
  @State private var isSigningIn = false
  @State private var showsEmailSignIn = false

  private var cloud: CloudAccountController { environment.cloud }

  var body: some View {
    NavigationStack {
      content
        // A readable column on iPad, matching onboarding.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if !isFinished {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { dismiss() }
                .disabled(request.isSending)
            }
          }
        }
    }
    .interactiveDismissDisabled(request.isSending)
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: cloud) }
    .onChange(of: cloud.state.isSignedIn) { _, _ in request.resetFailure() }
  }

  private var isFinished: Bool {
    request.phase == .approved || request.phase == .denied
  }

  @ViewBuilder
  private var content: some View {
    if let mismatch = cloud.deviceApprovalServerMismatch(for: request.link) {
      otherCloudContent(mismatch)
    } else if request.phase == .approved {
      finishedContent(
        symbol: "checkmark.circle.fill", tint: .green, title: "Machine connected",
        subtitle: "It will appear in your machines list in a moment."
      )
    } else if request.phase == .denied {
      finishedContent(
        symbol: "xmark.circle.fill", tint: .secondary, title: "Request denied",
        subtitle: "The machine won't be added to your account."
      )
    } else {
      switch cloud.state {
      case .signedOut: signInContent
      case .validating: ProgressView()
      case let .signedIn(userEmail): approvalContent(userEmail: userEmail)
      }
    }
  }

  // MARK: Approval

  private func approvalContent(userEmail: String?) -> some View {
    ScrollView {
      VStack(spacing: 20) {
        header(subtitle: "A machine is asking to sign in to your Codevisor account.")
        codeCard
        VStack(spacing: 0) {
          detailRow(label: "Account", value: userEmail ?? "Your Codevisor account")
          Divider().padding(.leading, 16)
          detailRow(label: "Server", value: request.link.host)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        Label(
          "Only approve codes you requested yourself. An approved machine joins your account and can run agents for you.",
          systemImage: "exclamationmark.shield"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 24)
    }
    .safeAreaInset(edge: .bottom) { approvalActions }
  }

  private var approvalActions: some View {
    VStack(spacing: 8) {
      if case let .failed(message, retry) = request.phase {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 4)
          .accessibilityIdentifier("deviceApproval.error")
        if let retry {
          Button(retry == .approve ? "Try Again" : "Try Denying Again") { send(retry) }
            .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
        } else {
          Button("Close") { dismiss() }
            .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
        }
      } else {
        Button("Approve") { send(.approve) }
          .buttonStyle(
            OnboardingFilledButtonStyle(
              background: .accentColor, foreground: .white,
              showsProgress: request.phase == .sending(.approve))
          )
          .disabled(request.isSending)
          .accessibilityIdentifier("deviceApproval.approve")
        Button(role: .destructive) {
          send(.deny)
        } label: {
          HStack(spacing: 8) {
            Text("Deny")
            if request.phase == .sending(.deny) { ProgressView().controlSize(.small) }
          }
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .disabled(request.isSending)
        .accessibilityIdentifier("deviceApproval.deny")
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .background(Color(.systemBackground))
  }

  private func send(_ decision: CloudDeviceApprovalRequest.Decision) {
    Task { await request.send(decision, cloud: cloud) }
  }

  // MARK: Sign-in

  private var signInContent: some View {
    ScrollView {
      VStack(spacing: 20) {
        header(subtitle: "Sign in to the Codevisor account this machine should join, then approve it.")
        codeCard
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 24)
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 12) {
        if let lastError = cloud.lastError {
          Text(lastError)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        if cloud.supportsGitHubSignIn {
          CloudSignInProviderButton(title: "Sign in with GitHub", icon: .asset("GitHubMark")) {
            startSignIn(.github)
          }
        }
        if cloud.supportsAppleSignIn {
          CloudAppleSignInButton { startSignIn(.apple) }
        }
        if cloud.supportsEmailSignIn {
          CloudEmailSignInButton { showsEmailSignIn = true }
        }
        if cloud.developmentAccountAvailable {
          CloudSignInProviderButton(title: "Use Development Account", icon: .system("hammer")) {
            Task { await cloud.signInWithDevelopmentAccount() }
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 12)
      .background(Color(.systemBackground))
    }
    .task { await cloud.refreshAuthProviders() }
  }

  private func startSignIn(_ provider: CloudSignInProvider) {
    guard !isSigningIn else { return }
    isSigningIn = true
    Task {
      await authentication.signIn(provider: provider, cloud: cloud)
      isSigningIn = false
    }
  }

  // MARK: Other states

  private func otherCloudContent(_ mismatch: CloudDeviceApprovalError) -> some View {
    resultLayout(
      symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Can't authorize this machine",
      subtitle: mismatch.localizedDescription, button: "Close"
    )
  }

  private func finishedContent(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
    resultLayout(symbol: symbol, tint: tint, title: title, subtitle: subtitle, button: "Done")
  }

  private func resultLayout(
    symbol: String, tint: Color, title: String, subtitle: String, button: String
  )
    -> some View
  {
    VStack(spacing: 16) {
      Spacer().frame(height: 48)
      Image(systemName: symbol)
        .font(.system(size: 60))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(title)
        .font(.title.bold())
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 28)
    .safeAreaInset(edge: .bottom) {
      Button(button) { dismiss() }
        .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityIdentifier("deviceApproval.done")
    }
  }

  // MARK: Building blocks

  private func header(subtitle: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "laptopcomputer.and.iphone")
        .font(.system(size: 52))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("Authorize this machine?")
        .font(.title.bold())
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 24)
  }

  /// The code the machine's terminal shows, so the user can check they
  /// scanned their own request.
  private var codeCard: some View {
    VStack(spacing: 6) {
      Text(request.link.userCode.uppercased())
        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
        .tracking(2)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .textSelection(.enabled)
        .accessibilityIdentifier("deviceApproval.code")
      Text("Check that this matches the code on the machine.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .padding(.horizontal, 16)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func detailRow(label: String, value: String) -> some View {
    HStack(spacing: 12) {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.subheadline)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
  }
}
