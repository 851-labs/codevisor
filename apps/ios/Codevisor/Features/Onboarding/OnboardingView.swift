import CodevisorCore
import CodevisorUI
import SwiftUI

struct OnboardingView: View {
  enum Step {
    case welcome
    case connect
  }

  var start: Step = .welcome

  static let readableWidth: CGFloat = 560

  var body: some View {
    NavigationStack {
      Group {
        switch start {
        case .welcome: WelcomeStep()
        case .connect: ConsentAndConnectStep()
        }
      }
      .frame(maxWidth: Self.readableWidth)
      .frame(maxWidth: .infinity)
      .background(Color(.systemBackground))
    }
  }
}

private struct WelcomeStep: View {
  private var title: String {
    guard CodevisorAppVariant.isDevelopment,
      CodevisorAppVariant.developmentInstanceID != nil
    else { return "Codevisor" }
    return "Codevisor (\(CodevisorAppVariant.developmentWorktreeName))"
  }

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
        .frame(height: 96)
      CodevisorAppIconView(size: 96)
      Text(title)
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text("Control your agents from anywhere.")
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 12) {
        NavigationLink {
          ConsentAndConnectStep()
        } label: {
          Text("Continue")
        }
        .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
        .accessibilityIdentifier("onboarding.continue")

        Text(
          "By continuing, you agree to our [Terms of Service](https://www.codevisor.dev/terms) and acknowledge our [Privacy Policy](https://www.codevisor.dev/privacy)."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .tint(.accentColor)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 12)
    }
    .toolbarVisibility(.hidden, for: .navigationBar)
  }
}

private struct ConsentAndConnectStep: View {
  @ClientPreference(AIDataSharingConsent.preferenceKey, default: 0)
  private var consentVersion

  var body: some View {
    Group {
      if consentVersion == AIDataSharingConsent.currentVersion {
        ConnectMachineStep()
      } else {
        AIDataSharingConsentScreen {
          consentVersion = AIDataSharingConsent.currentVersion
        }
      }
    }
  }
}

private struct ConnectMachineStep: View {
  @Environment(AppEnvironment.self) private var environment

  @State private var cloudSignIn = CloudAuthenticationCoordinator()
  @State private var isSigningInToCloud = false
  @State private var showsSettings = false
  @State private var showsEmailSignIn = false
  @State private var hasCompletedFirstMachinesCheck = false

  private var cloud: CloudAccountController { environment.cloud }

  private var showsLocalNetworkStep: Bool {
    cloud.state.isSignedIn && environment.needsLocalNetworkChoice
  }

  var body: some View {
    ZStack {
      switch cloud.state {
      case .signedOut:
        signedOutContent
      case .validating:
        checkingContent
      case let .signedIn(userEmail):
        if showsLocalNetworkStep {
          OnboardingLocalNetworkScreen()
        } else if !hasCompletedFirstMachinesCheck {
          checkingContent
            .task {
              await cloud.refreshMachines()
              hasCompletedFirstMachinesCheck = true
            }
        } else if cloud.machines.isEmpty {
          installAndLoginContent(userEmail: userEmail)
        } else {
          checkingContent
        }
      }
    }
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !showsLocalNetworkStep {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Settings", systemImage: "gearshape") { showsSettings = true }
            .accessibilityIdentifier("onboarding.settings")
        }
      }
    }
    .sheet(isPresented: $showsSettings) { SettingsSheet() }
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: cloud) }
    .onChange(of: cloud.state.isSignedIn) { _, _ in
      hasCompletedFirstMachinesCheck = false
    }
  }

  private var signedOutContent: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 96)
      OnboardingHero(
        symbol: "lock.icloud",
        title: "Connect your machines",
        subtitle: "See and connect to all of your machines from anywhere. End-to-end encrypted."
      )
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 12) {
        if let lastError = cloud.lastError {
          Text(lastError)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
        }

        if cloud.supportsGitHubSignIn {
          CloudSignInProviderButton(
            title: "Sign in with GitHub",
            icon: .symbol(.gitHubMark)
          ) { startCloudSignIn() }
        }

        if cloud.supportsAppleSignIn {
          CloudAppleSignInButton { startCloudSignIn(provider: .apple) }
        }

        if cloud.supportsEmailSignIn {
          CloudEmailSignInButton { showsEmailSignIn = true }
        }

        if cloud.developmentAccountAvailable {
          CloudSignInProviderButton(
            title: "Use Development Account",
            icon: .system("hammer")
          ) {
            Task { await cloud.signInWithDevelopmentAccount() }
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 12)
    }
  }

  private var checkingContent: some View {
    ProgressView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func installAndLoginContent(userEmail _: String?) -> some View {
    ScrollView {
      VStack(spacing: 8) {
        Spacer()
          .frame(height: 40)
        Text("Add your first machine")
          .font(.headline)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, alignment: .center)
        Text("Run these on the Mac or Linux machine you want to use — it signs itself into this account.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, alignment: .center)
          .fixedSize(horizontal: false, vertical: true)

        VStack(spacing: 0) {
          instructionStep(
            1,
            text: "Install Codevisor.",
            command: "curl -fsSL https://www.codevisor.dev/install.sh | sh"
          )
          Divider().padding(.leading, 46)
          instructionStep(
            2,
            text: "Sign in on that machine.",
            command: "codevisor auth login"
          )
        }
        .padding(.vertical, 4)
        .background(
          Color(.secondarySystemBackground),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.top, 6)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 24)
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        if Task.isCancelled { break }
        await cloud.refreshMachines()
      }
    }
  }

  private func instructionStep(_ number: Int, text: String, command: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      stepNumber(number)
      VStack(alignment: .leading, spacing: 8) {
        Text(text)
          .font(.subheadline.weight(.medium))
        CommandChip(command: command)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
  }

  private func stepNumber(_ number: Int) -> some View {
    Text("\(number)")
      .font(.footnote.weight(.bold))
      .foregroundStyle(.tint)
      .scaledFrame(width: 24, height: 24, relativeTo: .footnote)
      .background(Color.accentColor.opacity(0.14), in: Circle())
  }

  private func startCloudSignIn(provider: CloudSignInProvider = .github) {
    guard !isSigningInToCloud else { return }
    isSigningInToCloud = true
    Task {
      await cloudSignIn.signIn(provider: provider, cloud: environment.cloud)
      isSigningInToCloud = false
    }
  }
}

struct OnboardingHero: View {
  let symbol: String
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: symbol)
        .font(.system(size: Typography.IconSize.hero, weight: .medium))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text(title)
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
    }
    .padding(.horizontal, 24)
  }
}

struct OnboardingFilledButtonStyle: ButtonStyle {
  var background: Color
  var foreground: Color
  var showsProgress = false

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.label
        .font(.body.weight(.semibold))
      if showsProgress {
        ProgressView()
          .controlSize(.small)
          .tint(foreground)
      }
    }
    .foregroundStyle(foreground)
    .frame(maxWidth: .infinity, minHeight: 50)
    .background(
      background.opacity(configuration.isPressed ? 0.82 : 1),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct CommandChip: View {
  let command: String
  @State private var copied = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(command)
        .font(.callout.monospaced())
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        UIPasteboard.general.string = command
        withAnimation(.snappy(duration: 0.2)) { copied = true }
        Task {
          try? await Task.sleep(for: .seconds(1.5))
          withAnimation { copied = false }
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.caption)
          .foregroundStyle(copied ? .green : .secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Copy command")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
  }
}
