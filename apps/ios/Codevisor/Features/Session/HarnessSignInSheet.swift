import CodevisorCore
import SwiftUI

extension Notification.Name {
    /// Posted by chat error rows that need the sign-in sheet — HomeView
    /// observes it and presents over whatever surface raised the error.
    static let codevisorHarnessSignIn = Notification.Name("codevisor.harness-sign-in")
}

/// One harness on one machine that needs signing in — the payload every
/// sign-in presentation carries, sheet-item and notification alike.
struct HarnessSignInRequest: Identifiable {
    let serverId: String
    let harnessId: String
    /// Skips the lookup when the presenter already holds the harness row.
    var initialHarness: ServerHarness?

    var id: String { "\(serverId)|\(harnessId)" }

    func post() {
        NotificationCenter.default.post(
            name: .codevisorHarnessSignIn,
            object: nil,
            userInfo: ["serverId": serverId, "harnessId": harnessId]
        )
    }

    init(serverId: String, harnessId: String, initialHarness: ServerHarness? = nil) {
        self.serverId = serverId
        self.harnessId = harnessId
        self.initialHarness = initialHarness
    }

    init?(notification: Notification) {
        guard
            let serverId = notification.userInfo?["serverId"] as? String,
            let harnessId = notification.userInfo?["harnessId"] as? String
        else { return nil }
        self.init(serverId: serverId, harnessId: harnessId)
    }
}

/// The in-flow sign-in surface: presents the full harness authentication
/// experience (browser, device-code, API-key, or terminal flows) for ONE
/// harness on ONE machine, wherever the need surfaces — the model picker's
/// "sign in required" rows, an auth-dead chat — so nobody has to know
/// Settings exists to get a fleet machine working.
struct HarnessSignInSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let request: HarnessSignInRequest

    @State private var harness: ServerHarness?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { finish() }
                    }
                }
        }
        .task {
            guard harness == nil else { return }
            if let initial = request.initialHarness {
                harness = initial
                return
            }
            harness = try? await environment.machines.client(for: request.serverId)
                .listHarnesses()
                .first { $0.id == request.harnessId }
            loadFailed = harness == nil
        }
        .onDisappear {
            // Whatever happened in the flow, the machine's catalog is now
            // suspect — the revision bump refreshes any mounted composer.
            environment.harnessCatalogDidChange(onServer: request.serverId)
        }
    }

    private var title: String {
        harness?.name ?? request.harnessId
    }

    @ViewBuilder
    private var content: some View {
        if let harness {
            HarnessAuthenticationScreen(
                serverId: request.serverId,
                harness: harness,
                onAuthenticated: { finish() }
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
        environment.harnessCatalogDidChange(onServer: request.serverId)
        dismiss()
    }
}

extension View {
    /// Presents the sign-in sheet bound to an optional request.
    func harnessSignInSheet(request: Binding<HarnessSignInRequest?>) -> some View {
        sheet(item: request) { pending in
            HarnessSignInSheet(request: pending)
        }
    }
}
