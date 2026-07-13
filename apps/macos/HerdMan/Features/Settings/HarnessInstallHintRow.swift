import SwiftUI
import HerdManCore

/// A "not installed" harness row: icon, name, readiness detail, and — when
/// the catalog knows an installer — a copyable install command. Shared by
/// onboarding's harness step and Settings' harness list.
struct HarnessInstallHintRow: View {
    let harness: ServerHarness

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 15)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                Text(harness.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(harness.readiness.detail ?? "Not installed")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            if let installHint = harness.installHint {
                InstallCommandChip(command: installHint)
                    .padding(.leading, 30)
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
            installHint: "curl -fsSL https://claude.ai/install.sh | bash"
        ))
        HarnessInstallHintRow(harness: ServerHarness(
            id: "gemini", name: "Gemini CLI", symbolName: "diamond", source: "registry",
            launchKind: "npx", enabled: true,
            readiness: ServerHarnessReadiness(state: "unavailable", detail: "Requires npx")
        ))
    }
    .padding()
    .frame(width: 440)
}
