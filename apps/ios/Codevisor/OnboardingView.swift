import CodevisorCore
import CodevisorUI
import SwiftUI

/// First-launch onboarding: a welcome page, then a cloud-first "connect"
/// page. The connect step is state-driven off `environment.cloud`:
/// signed out leads with Codevisor Cloud sign-in, signed-in-with-no-machines
/// shows install-and-login instructions (the machine logs itself into the
/// same account), and signed-in-with-machines is a brief success state before
/// the cover dismisses itself. A secondary "Set up a machine manually" path
/// keeps the old QR / tailnet / manual-entry pairing behind a NavigationLink.
///
/// Layout follows the iOS onboarding convention throughout: the hero glyph,
/// title, and supporting content sit in the upper/centre of the screen while
/// the primary actions are pinned to the bottom safe area as full-width
/// buttons. All colours are semantic so both light and dark mode adapt.
struct OnboardingView: View {
    enum Step {
        case welcome
        case connect
    }

    /// Where the flow opens: the full welcome on first launch, straight to
    /// connect when reopened from the empty home screen.
    var start: Step = .welcome

    var body: some View {
        NavigationStack {
            switch start {
            case .welcome: WelcomeStep()
            case .connect: ConnectMachineStep()
            }
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    private var title: String {
        guard CodevisorAppVariant.isDevelopment,
              CodevisorAppVariant.developmentInstanceID != nil
        else { return "Codevisor" }
        return "Codevisor (\(CodevisorAppVariant.developmentWorktreeName))"
    }

    var body: some View {
        VStack(spacing: 16) {
            // Anchored in the top third: a fixed top offset, hero, then a
            // flexible Spacer fills the rest so the bottom action stays put.
            Spacer()
                .frame(height: 96)
            CodevisorAppIconView(size: 96)
            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                // Take the vertical room to wrap onto two lines rather than
                // truncating "Codevisor" to an ellipsis.
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
            NavigationLink {
                ConnectMachineStep()
            } label: {
                Text("Get Started")
            }
            .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
            .accessibilityLabel("Get Started")
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
    }
}

// MARK: - Connect

/// The cloud-first connect page. Sign-in is the primary path; the manual QR /
/// tailnet / add-machine flow lives one tap away behind "Set up a machine
/// manually" so it never crowds the initial screen.
private struct ConnectMachineStep: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var cloudSignIn = CloudSignInCoordinator()
    @State private var isSigningInToCloud = false

    private var cloud: CloudAccountController { environment.cloud }

    var body: some View {
        Group {
            switch cloud.state {
            case .signedOut:
                signedOutContent
            case .validating:
                validatingContent
            case let .signedIn(userEmail):
                if cloud.machines.isEmpty {
                    installAndLoginContent(userEmail: userEmail)
                } else {
                    signedInReadyContent(userEmail: userEmail)
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Signed out (primary path)

    private var signedOutContent: some View {
        VStack(spacing: 0) {
            // Same top-third anchor as the Welcome screen: fixed top offset,
            // hero, then a flexible Spacer down to the bottom action stack.
            Spacer()
                .frame(height: 96)
            hero(
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
                    Button(action: startCloudSignIn) {
                        Label {
                            Text("Sign in with GitHub")
                        } icon: {
                            gitHubMark
                        }
                    }
                    .buttonStyle(
                        OnboardingFilledButtonStyle(
                            background: Color(.label),
                            foreground: Color(.systemBackground)
                        )
                    )
                    .disabled(isSigningInToCloud)
                    .accessibilityLabel("Sign in with GitHub")
                }

                if cloud.developmentAccountAvailable {
                    Button {
                        Task { await cloud.signInWithDevelopmentAccount() }
                    } label: {
                        Label {
                            Text("Use Development Account")
                        } icon: {
                            Image(systemName: "hammer")
                        }
                    }
                    .buttonStyle(OnboardingOutlineButtonStyle())
                    .disabled(isSigningInToCloud)
                    .accessibilityLabel("Use Development Account")
                }

                secondaryManualLink
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: Validating

    private var validatingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Signing in…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Signed in, machines ready (brief success)

    private func signedInReadyContent(userEmail: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(.title.bold())
            VStack(spacing: 4) {
                Text("Signed in as \(userEmail ?? "your account").")
                Text("Your machines are ready.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Signed in, no machines yet (install + login instructions)

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
        .safeAreaInset(edge: .bottom) {
            secondaryManualLink
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        // Poll while this state is on screen so a machine that logs into the
        // same account shows up without any user action — when it arrives the
        // list becomes non-empty and the flow advances / the cover dismisses.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await cloud.refreshMachines()
            }
        }
    }

    // MARK: Building blocks

    private func hero(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 60))
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

    private var gitHubMark: some View {
        Image("GitHubMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
    }

    private var secondaryManualLink: some View {
        NavigationLink {
            ManualSetupView()
        } label: {
            Text("Set up a machine manually")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set up a machine manually")
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
            // Scales with Dynamic Type so the footnote digit never outgrows
            // its circle at accessibility text sizes.
            .scaledFrame(width: 24, height: 24, relativeTo: .footnote)
            .background(Color.accentColor.opacity(0.14), in: Circle())
    }

    // MARK: Cloud sign-in

    private func startCloudSignIn() {
        let scheme = CloudSignInCoordinator.callbackScheme
        isSigningInToCloud = true
        environment.cloud.lastError = nil
        cloudSignIn.start(
            url: environment.cloud.signInURL(scheme: scheme),
            callbackScheme: scheme
        ) { callbackURL in
            isSigningInToCloud = false
            guard let callbackURL,
                  let deeplink = CloudAuthDeeplink.parse(callbackURL)
            else { return }
            Task { await environment.cloud.completeSignIn(ott: deeplink.ott) }
        }
    }
}

// MARK: - Onboarding button styles

/// A full-width, large filled button shared by the onboarding CTAs so the
/// "Get Started" and "Sign in with GitHub" actions line up pixel-for-pixel.
/// Colours are passed in so the same style renders both the accent primary
/// and the classic label-on-background OAuth look.
private struct OnboardingFilledButtonStyle: ButtonStyle {
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

/// A full-width, large outlined secondary button — a clean tinted outline,
/// never a filled gray blob.
private struct OnboardingOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Manual setup (secondary path)

/// The old pairing surface, now reached from "Set up a machine manually": the
/// QR setup steps, the tailnet section (when discovery finds servers), the
/// same Add-Machine form macOS uses, and the dev-remote quick-add.
private struct ManualSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var discovery = TailnetMachineDiscovery()
    @State private var discoveredTarget: TailnetMachineDiscovery.Discovered?
    @State private var isAddingManually = false

    @State private var isConnecting = false
    @State private var developmentError: String?

    var body: some View {
        List {
            setupSection
            if !discovery.discovered.isEmpty {
                tailnetSection
            }
            manualSection
            if let devRemote = CodevisorAppVariant.developmentRemote {
                developmentSection(devRemote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Set Up Manually")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingManually) {
            AddMachineSheet()
        }
        .sheet(item: $discoveredTarget) { machine in
            AddMachineSheet(initialHost: machine.host, initialName: machine.name)
        }
        // Discover only while this page is on screen — no background polling.
        // (Discovery needs a paired machine to relay through, so on a true
        // first launch the section stays hidden and the QR flow leads.)
        .task {
            while !Task.isCancelled {
                await discovery.refresh(machines: environment.machines)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Setup steps

    private var setupSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                stepNumber(1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install Codevisor on your Mac or Linux machine.")
                    CommandChip(command: "curl -fsSL https://www.codevisor.dev/install.sh | sh")
                }
            }
            .padding(.vertical, 2)
            HStack(alignment: .top, spacing: 12) {
                stepNumber(2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run the setup command in a terminal there.")
                    CommandChip(command: "codevisor setup")
                }
            }
            .padding(.vertical, 2)
            stepRow(3, text: "Scan the QR code it prints with your camera — this app connects automatically.")
        } header: {
            Text("On Your Machine")
        }
    }

    private func stepRow(_ number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepNumber(number)
            Text(text)
        }
        .padding(.vertical, 2)
    }

    private func stepNumber(_ number: Int) -> some View {
        Text("\(number)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: 22, height: 22)
            .background(Color.accentColor.opacity(0.12), in: Circle())
    }

    // MARK: Tailnet

    /// Codevisor servers found on the tailnet (relayed through a paired
    /// machine and probed from this phone) — only rendered when non-empty.
    private var tailnetSection: some View {
        Section {
            ForEach(discovery.discovered) { machine in
                Button {
                    discoveredTarget = machine
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.name)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text("\(machine.host) · Codevisor \(machine.version)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("On Your Tailnet")
        } footer: {
            Text("Codevisor servers found on your tailnet. Adding one still needs its connection token.")
        }
    }

    // MARK: Manual entry

    private var manualSection: some View {
        Section {
            Button {
                isAddingManually = true
            } label: {
                Label("Add Machine Manually", systemImage: "plus.circle")
            }
        }
    }

    // MARK: Development

    /// Dev-only shortcut, mirroring macOS Settings → Machines: the dev remote
    /// that `bun run dev:ios` started shows as a machine you can quick-add —
    /// one tap connects, no token entry.
    private func developmentSection(_ remote: CodevisorAppVariant.DevelopmentRemote) -> some View {
        Section {
            Button {
                Task { await connectDevelopment(remote) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remote.name)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        Text(remote.hostWithPort)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isConnecting {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.vertical, 2)
            }
            .disabled(isConnecting)
        } header: {
            Text("Development")
        } footer: {
            if let developmentError {
                Text(developmentError)
                    .foregroundStyle(.red)
            }
        }
    }

    private func connectDevelopment(_ remote: CodevisorAppVariant.DevelopmentRemote) async {
        isConnecting = true
        developmentError = nil
        defer { isConnecting = false }
        do {
            let added = try await environment.machines.addRemoteValidating(
                host: remote.hostWithPort,
                name: remote.name,
                token: remote.token
            )
            environment.machines.selectMachine(added.id)
            await environment.prepareSelectedMachine()
            dismiss()
        } catch {
            developmentError = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

// MARK: - Command chip

/// A copyable terminal command: monospaced text in a soft capsule with a
/// copy button that flashes a checkmark.
private struct CommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                // Wraps rather than shrinking: `minimumScaleFactor` would
                // render below the HIG 11 pt minimum and fight the user's
                // Dynamic Type setting.
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
