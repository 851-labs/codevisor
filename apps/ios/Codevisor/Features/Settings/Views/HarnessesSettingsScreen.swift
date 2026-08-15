import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Harnesses

struct HarnessesSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var harnesses: [ServerHarness] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var installed: [ServerHarness] {
        harnesses.filter { $0.readiness.state != "notInstalled" }
    }

    private var notInstalled: [ServerHarness] {
        harnesses.filter { $0.readiness.state == "notInstalled" }
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Section("Installed") {
                    ForEach(installed, id: \.id) { harness in
                        harnessRow(harness)
                    }
                }
                if !notInstalled.isEmpty {
                    Section("Not Installed") {
                        ForEach(notInstalled, id: \.id) { harness in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(harness.name)
                                if let hint = harness.installHint {
                                    Text(hint)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Harnesses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh harnesses")
            }
        }
        .task { await load() }
    }

    private func harnessRow(_ harness: ServerHarness) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                if let auth = harness.auth, auth.state != "authenticated" {
                    Text("Sign in on your machine to use")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle(
                "Enable \(harness.name)",
                isOn: Binding(
                    get: { harness.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setHarnessEnabled(
                                id: harness.id, enabled: enabled
                            )
                            await load()
                        }
                    }
                )
            )
            .labelsHidden()
        }
    }

    private func load() async {
        do {
            harnesses = try await client.listHarnesses()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}
