import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Skills

struct SkillsSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var scan: ServerSkillsScan?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let scan {
                if scan.global.isEmpty {
                    ContentUnavailableView {
                        Label("No Skills", systemImage: "book.closed")
                    } description: {
                        Text("Skills are reusable instruction sets shared with your coding agents.")
                    }
                } else {
                    Section("Global Skills") {
                        ForEach(scan.global, id: \.id) { skill in
                            skillRow(skill)
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sync") {
                    Task {
                        scan = try? await client.syncSkills(directoryNames: nil)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func skillRow(_ skill: ServerGlobalSkill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name)
            if let description = skill.description, !description.isEmpty {
                // No detail screen exists, so the row is the only place this
                // description can be read — let it wrap fully.
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    scan = try? await client.removeSkill(directoryName: skill.directoryName)
                }
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
    }

    private func load() async {
        do {
            scan = try await client.listSkills()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}
