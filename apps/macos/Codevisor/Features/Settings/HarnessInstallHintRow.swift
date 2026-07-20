import SwiftUI
import CodevisorCore

/// A "not installed" harness row: icon, name, readiness detail, and — when
/// the server can run an installer — a one-click Install button with a
/// confirmation popover showing the exact command. Falls back to the
/// copyable install command when no method is runnable on the machine.
/// Shared by onboarding's harness step and Settings' harness list.
struct HarnessInstallHintRow: View {
    let harness: ServerHarness

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    @State private var showsConfirm = false
    @State private var isStarting = false
    @State private var startError: String?

    private var availableMethods: [ServerHarnessInstallMethod] {
        (harness.installMethods ?? []).filter(\.available)
    }

    private var lifecyclePhase: String? { harness.lifecycle?.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 15)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                Text(harness.name)
                    .foregroundStyle(.secondary)
                Spacer()
                trailingContent
            }
            if let failure = failureMessage {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(theme.statusWarn)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
            if availableMethods.isEmpty, let installHint = harness.installHint {
                // No runnable method (missing brew/npm) — keep the copyable
                // command so the user can install from a terminal.
                InstallCommandChip(command: installHint)
                    .padding(.leading, 30)
            }
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        if lifecyclePhase == "installing" || isStarting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(installingLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if !availableMethods.isEmpty {
            Button(lifecyclePhase == "failed" ? "Try Again" : "Install") {
                showsConfirm = true
            }
            .popover(isPresented: $showsConfirm, arrowEdge: .bottom) {
                HarnessInstallPopover(harness: harness, methods: availableMethods) { methodId in
                    showsConfirm = false
                    Task { await install(methodId: methodId) }
                }
            }
        } else {
            Text(harness.readiness.detail ?? "Not installed")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private var installingLabel: String {
        guard let methodId = harness.lifecycle?.methodId else { return "Installing…" }
        switch methodId {
        case "brew": return "Installing via Homebrew…"
        case "npm": return "Installing via npm…"
        default: return "Installing…"
        }
    }

    private var failureMessage: String? {
        startError ?? (lifecyclePhase == "failed" ? harness.lifecycle?.error : nil)
    }

    private func install(methodId: String) async {
        isStarting = true
        startError = nil
        defer { isStarting = false }
        let serverId = environment.machines.selectedMachineId
        do {
            _ = try await environment.machines.client(for: serverId)
                .installHarness(id: harness.id, methodId: methodId)
            // Progress arrives via harness.lifecycle.updated events → catalog
            // revision bumps → the hosting list refetches.
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            startError = error.localizedDescription
        }
    }
}

/// Confirmation before running an installer: which method (remembered), and
/// the exact command that will run — nothing hidden.
struct HarnessInstallPopover: View {
    let harness: ServerHarness
    let methods: [ServerHarnessInstallMethod]
    let onInstall: (String) -> Void

    @AppStorage private var preferredMethodId: String
    @State private var selectedMethodId: String

    init(
        harness: ServerHarness,
        methods: [ServerHarnessInstallMethod],
        onInstall: @escaping (String) -> Void
    ) {
        self.harness = harness
        self.methods = methods
        self.onInstall = onInstall
        let storage = AppStorage(
            wrappedValue: methods.first(where: \.recommended)?.id ?? methods.first?.id ?? "",
            "harnessInstallMethod.\(harness.id)"
        )
        _preferredMethodId = storage
        _selectedMethodId = State(initialValue: storage.wrappedValue)
    }

    private var selectedMethod: ServerHarnessInstallMethod? {
        methods.first { $0.id == selectedMethodId } ?? methods.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install \(harness.name)")
                .font(.headline)
            if methods.count > 1 {
                Picker("Install using", selection: $selectedMethodId) {
                    ForEach(methods, id: \.id) { method in
                        Text(method.label).tag(method.id)
                    }
                }
                .pickerStyle(.menu)
            }
            if let method = selectedMethod {
                Text(method.command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Spacer()
                Button("Install") {
                    guard let method = selectedMethod else { return }
                    preferredMethodId = method.id
                    onInstall(method.id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            // A remembered method that is no longer runnable falls back to
            // the current recommendation.
            if !methods.contains(where: { $0.id == selectedMethodId }) {
                selectedMethodId = methods.first(where: \.recommended)?.id ?? methods.first?.id ?? ""
            }
        }
    }
}

/// A monospaced, selectable install command with a copy button.
struct InstallCommandChip: View {
    let command: String

    @Environment(\.theme) private var theme
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? AnyShapeStyle(theme.statusOK) : AnyShapeStyle(theme.textSecondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Copy install command")
            .accessibilityLabel(copied ? "Copied" : "Copy install command")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        HarnessInstallHintRow(harness: ServerHarness(
            id: "claude-code", name: "Claude Code", symbolName: "sparkle", source: "registry",
            launchKind: "executable", enabled: true,
            readiness: ServerHarnessReadiness(state: "unavailable", detail: "CLI not found on PATH"),
            installHint: "curl -fsSL https://claude.ai/install.sh | bash",
            installMethods: [
                ServerHarnessInstallMethod(
                    id: "curl", kind: "curl", label: "Installer script",
                    command: "curl -fsSL https://claude.ai/install.sh | bash",
                    available: true, recommended: true
                ),
                ServerHarnessInstallMethod(
                    id: "npm", kind: "npm", label: "npm",
                    command: "npm install -g @anthropic-ai/claude-code",
                    available: true, recommended: false
                )
            ]
        ))
        HarnessInstallHintRow(harness: ServerHarness(
            id: "gemini", name: "Gemini CLI", symbolName: "diamond", source: "registry",
            launchKind: "npx", enabled: true,
            readiness: ServerHarnessReadiness(state: "unavailable", detail: "Requires npx")
        ))
    }
    .padding()
    .frame(width: 440)
    .environment(AppEnvironment.preview())
}
