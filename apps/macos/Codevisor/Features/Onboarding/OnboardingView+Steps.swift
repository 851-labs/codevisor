import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

extension OnboardingView {
    // MARK: - Content

    @ViewBuilder
    var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .analytics: analyticsStep
        case .harnesses: harnessesStep
        case .project: projectStep
        case .account: accountStep
        }
    }

    // MARK: - Permissions

    /// Continue unlocks when both Computer Use permissions are granted;
    /// "Set Up Later" skips and turns Computer Use off until the user
    /// re-enters setup from the Computer Use toggle in Settings.
    private var permissionsStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "lock.shield",
                title: "Allow Computer Use",
                subtitle: "Codevisor uses these to operate apps when you ask."
            )

            ComputerUsePermissionRowsView(model: permissions)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                .accessibilityHidden(true)

            Text("Welcome to Codevisor")
                .font(.heroTitle)
                .padding(.top, 22)

            Text("All your coding agents, working in one place.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Privacy

    /// A compact final-step consent card. Both choices start selected, remain
    /// independent, and are not persisted until the user continues.
    private var analyticsStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: Typography.IconSize.hero, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Help improve Codevisor")
                .font(.stepTitle)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Share anonymous usage metrics", isOn: $shareAnalytics)
                        .toggleStyle(.checkbox)
                        .fontWeight(.semibold)

                    Text("Shares anonymous product usage so we can understand what’s useful and what to improve.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Send crash and error reports", isOn: $shareCrashReports)
                        .toggleStyle(.checkbox)
                        .fontWeight(.semibold)

                    Text("Shares technical details when Codevisor crashes or encounters an error.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .padding(.top, 24)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your work stays private")
                        .font(.callout.weight(.semibold))

                    Text(
                        "Neither option includes prompts, responses, code, file paths, project names, browser content, or terminal commands."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.top, 12)

            Text("You can change this at any time in Settings → Privacy & Data.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cloud account

    /// The optional last step: connect the Codevisor Cloud account. Signing
    /// in is never required — "Skip for now" finishes setup, and the account
    /// stays available in Settings → Account. A dev environment may already
    /// be signed in (bootstrap adopts the dev cloud token), in which case the
    /// confirmation shows instead of the button.
    private var accountStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "icloud",
                title: "Connect your machines",
                subtitle: "Sign in to see and connect to all of your machines from anywhere. End-to-end encrypted."
            )

            Group {
                switch environment.cloud.state {
                case .signedOut:
                    VStack(spacing: 10) {
                        if environment.cloud.supportsGitHubSignIn {
                            CloudSignInProviderButton(
                                title: "Sign in with GitHub",
                                icon: .asset("GitHubMark")
                            ) { startCloudSignIn() }
                            .controlSize(.large)
                        }
                        if environment.cloud.developmentAccountAvailable {
                            CloudSignInProviderButton(
                                title: "Use Development Account",
                                icon: .system("person.crop.circle.dashed")
                            ) {
                                Task { await environment.cloud.signInWithDevelopmentAccount() }
                            }
                            .controlSize(.large)
                        }
                        if let lastError = environment.cloud.lastError {
                            Text(lastError)
                                .font(.callout)
                                .foregroundStyle(theme.statusWarn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Signing in…")
                            .foregroundStyle(.secondary)
                    }
                case let .signedIn(userEmail):
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(userEmail ?? "Signed in")
                                    .fontWeight(.medium)
                                Text("Your machines will show up here and on your other devices.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: 420, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(theme.cardBackground)
                        )
                        // Escape hatch for switching accounts mid-onboarding —
                        // in dev the app arrives pre-signed-in (dev-token
                        // adoption), and this is how you reach the real
                        // sign-in flow.
                        Button("Use a Different Account…") {
                            environment.cloud.signOut()
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The URL scheme this build registered (codevisor-dev for development
    /// builds), read from Info.plist so it always matches what the browser
    /// can actually call back to. Mirrors CloudSettingsView.
    private var cloudCallbackScheme: String {
        let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
            .first { $0.hasPrefix("codevisor") }
        return registered ?? (CodevisorAppVariant.isDevelopment ? "codevisor-dev" : "codevisor")
    }

    /// Opens the sign-in URL in the user's default browser; the handoff page
    /// bounces back via the cloud-auth deeplink handled in ContentView.
    private func startCloudSignIn() {
        environment.cloud.lastError = nil
        NSWorkspace.shared.open(environment.cloud.signInURL(scheme: cloudCallbackScheme))
    }

    // MARK: - Step header

    func stepHeader(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: Typography.IconSize.hero, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.stepTitle)
                .padding(.top, 18)

            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Projects

    private var projectStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "folder",
                title: "Choose your projects",
                subtitle: "Select the folders you want to work in."
            )

            // The same selection grid the new-chat empty state renders, so
            // both surfaces look and behave identically.
            ProjectSetupSelectionView(
                model: projectSetup,
                isLocalMachine: true,
                machineName: CodevisorMachine.local.name,
                onPickFolder: { showingFolderPicker = true },
                onCloneRepository: { showingGitClone = true }
            )
        }
        .frame(maxWidth: .infinity)
    }
}
