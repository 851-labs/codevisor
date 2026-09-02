import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Manual setup (secondary path)

/// The old pairing surface, now reached from "Set up a machine manually": the
/// QR setup steps, the tailnet section (when discovery finds servers), the
/// same Add-Machine form macOS uses, and the dev-remote quick-add.
struct ManualSetupView: View {
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
                            .scaledFrame(width: 30, relativeTo: .title3)
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
                        .scaledFrame(width: 30, relativeTo: .title3)
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
            environment.composerDefaults.rememberNewWorkspaceServer(serverId: added.id)
            await environment.prepareMachine(added.id)
            dismiss()
        } catch {
            developmentError = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
