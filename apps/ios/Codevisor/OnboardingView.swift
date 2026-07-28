import CodevisorCore
import SwiftUI

/// First-launch onboarding: a welcome page, then a guided "connect your
/// machine" page. Pairing works three ways — scan the QR that
/// `codevisor setup` prints (the camera deeplink adds the machine and
/// onboarding closes itself), pick a Codevisor server discovered on the
/// tailnet, or enter an address manually in the same form macOS uses.
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
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("hunk")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(.tint)
            Text("Welcome to Codevisor")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Text("Your coding agents, anywhere.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
            VStack(alignment: .leading, spacing: 22) {
                featureRow(
                    symbol: "desktopcomputer",
                    title: "Runs on your machines",
                    detail: "Agents work on a Mac or Linux machine you pair — your code never leaves it."
                )
                featureRow(
                    symbol: "bubble.left.and.bubble.right",
                    title: "Every agent, one app",
                    detail: "Chat with Claude Code, Codex, and more, side by side in workspaces."
                )
                featureRow(
                    symbol: "arrow.triangle.branch",
                    title: "Safe to walk away",
                    detail: "Branch work into worktrees, watch live progress, and pick up from any device."
                )
            }
            .padding(.horizontal, 12)
            Spacer()
            Spacer()
            NavigationLink {
                ConnectMachineStep()
            } label: {
                Text("Get Started")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .toolbarVisibility(.hidden, for: .navigationBar)
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Connect

/// The guided pairing page: setup steps for the remote machine, an
/// "On Your Tailnet" section that appears only when discovery actually
/// finds Codevisor servers, and a manual-entry button that opens the same
/// address + token form macOS shows for Add Remote Machine.
private struct ConnectMachineStep: View {
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
        .navigationTitle("Connect a Machine")
        .navigationBarTitleDisplayMode(.large)
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
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}
