import CodevisorCore
import SwiftUI

/// First-launch onboarding: a welcome page, then a guided "connect your
/// machine" page. Pairing works three ways, all live on one screen — scan
/// the QR that `codevisor setup` prints (the camera deeplink adds the
/// machine and onboarding closes itself), find a machine by its Tailscale
/// name when the phone is on a tailnet, or type a host address directly.
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
    @Environment(\.dismiss) private var dismiss

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
            Button("Set Up Later") { dismiss() }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.bottom, 6)
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

/// The guided pairing page: setup steps for the remote machine, then a
/// finder that probes the typed name or address for a Codevisor server —
/// framed around Tailscale when the phone is on a tailnet.
private struct ConnectMachineStep: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var tailnet: TailnetDiscovery.TailnetInfo?
    @State private var hasDetected = false

    @State private var hostInput = ""
    @State private var isProbing = false
    @State private var found: TailnetDiscovery.FoundMachine?
    @State private var searchedHost: String?

    @State private var token = ""
    @State private var isConnecting = false
    @State private var connectError: String?

    @State private var copiedCommand = false

    var body: some View {
        List {
            setupSection
            finderSection
            if let found {
                connectSection(found)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connect a Machine")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Later") { dismiss() }
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            tailnet = await TailnetDiscovery.detectTailscale()
            hasDetected = true
        }
        .task(id: hostInput) { await probeTyped() }
    }

    // MARK: Setup steps

    private var setupSection: some View {
        Section {
            stepRow(1, text: "Install Codevisor on your Mac or Linux machine.")
            HStack(spacing: 12) {
                stepNumber(2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run the setup command in a terminal there.")
                    HStack(spacing: 8) {
                        Text("codevisor setup")
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                        Button {
                            UIPasteboard.general.string = "codevisor setup"
                            withAnimation(.snappy(duration: 0.2)) { copiedCommand = true }
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                withAnimation { copiedCommand = false }
                            }
                        } label: {
                            Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(copiedCommand ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy setup command")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
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

    // MARK: Finder

    private var finderSection: some View {
        Section {
            TextField(
                tailscaleActive ? "Machine name or address" : "Host or IP address",
                text: $hostInput
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.search)

            if isProbing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for \(hostInput.trimmingCharacters(in: .whitespaces))…")
                        .foregroundStyle(.secondary)
                }
            } else if found == nil, let searchedHost {
                Label {
                    Text("No Codevisor server found at \(searchedHost).")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        } header: {
            Text(tailscaleActive ? "Find on Your Tailnet" : "Find by Address")
        } footer: {
            finderFooter
        }
    }

    @ViewBuilder private var finderFooter: some View {
        if let tailnet, tailscaleActive {
            Text(
                tailnet.tailnetName.isEmpty
                    ? "Tailscale is connected. Enter a machine's Tailscale name to find it."
                    : "Tailscale is connected to \(tailnet.tailnetName). Enter a machine's Tailscale name to find it."
            )
        } else if hasDetected {
            Text("Enter the machine's hostname or IP address. Codevisor listens on port \(String(CodevisorServerConfig.productionPort)).")
        }
    }

    private var tailscaleActive: Bool { tailnet != nil }

    /// Debounced live probe of the typed host for the tokenless
    /// `/v1/discovery` manifest — the same recognition the macOS tailnet
    /// section does per peer.
    private func probeTyped() async {
        found = nil
        searchedHost = nil
        connectError = nil
        let host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            isProbing = false
            return
        }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        isProbing = true
        defer { isProbing = false }
        let result = await TailnetDiscovery.probe(host)
        guard !Task.isCancelled else { return }
        found = result
        searchedHost = result == nil ? host : nil
    }

    // MARK: Connect

    private func connectSection(_ machine: TailnetDiscovery.FoundMachine) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: machine.manifest.platform == "linux" ? "server.rack" : "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.manifest.name)
                        .fontWeight(.medium)
                    Text("\(machine.host) · Codevisor \(machine.manifest.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .padding(.vertical, 2)

            SecureField("Connection token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await connect(machine) }
            } label: {
                HStack {
                    Spacer()
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text("Connect")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(isConnecting)
        } header: {
            Text("Machine Found")
        } footer: {
            if let connectError {
                Text(connectError)
                    .foregroundStyle(.red)
            } else {
                Text("The connection token is printed by codevisor setup, and shown in Codevisor's settings on that machine.")
            }
        }
    }

    /// Validated add, exactly like the macOS Add dialog: unreachable hosts
    /// and rejected tokens surface here instead of as a broken machine.
    private func connect(_ machine: TailnetDiscovery.FoundMachine) async {
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let added = try await environment.machines.addRemoteValidating(
                host: machine.host,
                name: machine.manifest.name,
                token: trimmedToken.isEmpty ? nil : trimmedToken
            )
            environment.machines.selectMachine(added.id)
            await environment.prepareSelectedMachine()
            dismiss()
        } catch {
            connectError = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
