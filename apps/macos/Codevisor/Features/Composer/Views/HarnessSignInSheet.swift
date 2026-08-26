import CodevisorCore
import SwiftUI

/// The in-flow sign-in surface: presents the full harness authentication
/// experience (browser, device-code, or API-key flows) for ONE harness on
/// ONE machine, wherever the need surfaces — the composer's model picker,
/// an auth-dead chat — so nobody has to know Settings exists to get a
/// fleet machine working. Reuses the settings/onboarding authentication
/// view verbatim, pinned to the target machine.
struct HarnessSignInSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let serverId: String
    let harnessId: String
    /// Skips the lookup when the presenter already holds the harness row.
    var initialHarness: ServerHarness? = nil

    @State private var harness: ServerHarness?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Done") { finish() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 380, idealHeight: 440)
        .environment(\.settingsMachineId, serverId)
        .task {
            guard harness == nil else { return }
            if let initialHarness {
                harness = initialHarness
                return
            }
            harness = try? await environment.machines.client(for: serverId)
                .listHarnesses()
                .first { $0.id == harnessId }
            loadFailed = harness == nil
        }
        .onDisappear {
            // Whatever happened in the flow, the machine's catalog is now
            // suspect — the revision bump refreshes any mounted composer.
            environment.harnessCatalogDidChange(onServer: serverId)
        }
    }

    private var title: String {
        let machine = environment.machines.machine(for: serverId)?.name ?? "this machine"
        return "Sign in to \(harness?.name ?? harnessId) on \(machine)"
    }

    @ViewBuilder
    private var content: some View {
        if let harness {
            HarnessAuthenticationView(
                harness: harness,
                onChange: { updated in
                    self.harness = updated
                    if updated.auth?.state == "authenticated" {
                        finish()
                    }
                },
                showsHeader: false
            )
        } else if loadFailed {
            ContentUnavailableView {
                Label("Harness Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Couldn't load the harness from the machine. Check its connection and try again.")
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func finish() {
        environment.harnessCatalogDidChange(onServer: serverId)
        dismiss()
    }
}

/// Sheet-item wrappers: ServerHarness itself is not Identifiable.
struct HarnessSignInTarget: Identifiable {
    let harnessId: String
    var id: String { harnessId }
}

struct PendingHarnessSignIn: Identifiable {
    let harness: ServerHarness
    var id: String { harness.id }
}

extension View {
    /// Presents the sign-in sheet bound to an optional harness id (auth-dead
    /// chats know only the id).
    func harnessSignInSheet(harnessId: Binding<String?>, serverId: String) -> some View {
        sheet(
            item: Binding(
                get: { harnessId.wrappedValue.map(HarnessSignInTarget.init(harnessId:)) },
                set: { harnessId.wrappedValue = $0?.harnessId }
            )
        ) { target in
            HarnessSignInSheet(serverId: serverId, harnessId: target.harnessId)
        }
    }

    /// Presents the sign-in sheet for a harness row the picker already holds.
    func harnessSignInSheet(harness: Binding<ServerHarness?>, serverId: String) -> some View {
        sheet(
            item: Binding(
                get: { harness.wrappedValue.map(PendingHarnessSignIn.init(harness:)) },
                set: { harness.wrappedValue = $0?.harness }
            )
        ) { pending in
            HarnessSignInSheet(
                serverId: serverId,
                harnessId: pending.harness.id,
                initialHarness: pending.harness
            )
        }
    }
}

/// The model picker's "sign in required" rows for fleet-enabled harnesses
/// blocked on auth — selection hands the harness to the sign-in sheet.
struct SignInRequiredRows: View {
    let harnesses: [ServerHarness]
    let onSelect: (ServerHarness) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sign in required")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            ForEach(harnesses, id: \.id) { harness in
                Button {
                    onSelect(harness)
                } label: {
                    HStack(spacing: 8) {
                        HarnessIcon(
                            harnessId: harness.id,
                            fallbackSymbolName: harness.symbolName,
                            size: 14
                        )
                        .frame(width: 16, height: 16)
                        Text(harness.name)
                        Spacer(minLength: 8)
                        Text("Sign In")
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .help("Sign in to \(harness.name) on this machine")
            }
        }
        .padding(.bottom, 6)
    }
}
