import SwiftUI
import CodevisorCore

/// A directory picker for remote machines, backed by the server's
/// `/v1/fs/list` endpoint: breadcrumbs, an editable path field for power
/// users, and a git badge on folders that are repositories.
struct RemoteDirectoryBrowserSheet: View {
    let client: any CodevisorServerClienting
    let machineName: String
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listing: ServerFsListing?
    @State private var pathField = ""
    @State private var showHidden = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a folder on \(machineName)")
                .font(.headline)

            HStack(spacing: 6) {
                Button {
                    navigate(to: listing?.parent)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .disabled(listing?.parent == nil || isLoading)
                .help("Parent folder")
                .accessibilityLabel("Parent folder")

                TextField("/home/user/projects", text: $pathField)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { navigate(to: pathField) }
            }

            Group {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Can't Open Folder", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(errorMessage)
                    }
                } else if let listing {
                    List(listing.entries, id: \.path) { entry in
                        Button {
                            navigate(to: entry.path)
                        } label: {
                            HStack {
                                Image(systemName: entry.isGitRepo ? "folder.fill.badge.gearshape" : "folder")
                                    .foregroundStyle(.secondary)
                                Text(entry.name)
                                Spacer()
                                if entry.isGitRepo {
                                    Text("git")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                    .overlay {
                        if listing.entries.isEmpty {
                            Text("No subfolders")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 260)

            Toggle("Show hidden folders", isOn: $showHidden)
                .onChange(of: showHidden) { _, _ in
                    navigate(to: listing?.path ?? pathField)
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Choose This Folder") {
                    if let path = listing?.path {
                        onChoose(path)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(listing == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .task { navigate(to: nil) }
    }

    /// Loads a directory (nil = the server's home). Failures keep the last
    /// good listing so a typo in the path field is recoverable.
    private func navigate(to path: String?) {
        guard !isLoading || path != nil else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let next = try await client.listDirectory(path: path, showHidden: showHidden)
                listing = next
                pathField = next.path
                errorMessage = nil
            } catch {
                errorMessage = Self.guidance(
                    code: serverErrorCode(error),
                    fallback: serverErrorMessage(error),
                    machineName: machineName
                )
            }
        }
    }

    /// Actionable messages for the server's classified `fs/list` failures.
    /// The fallback is the server's own error sentence (or the connection
    /// failure message).
    static func guidance(code: String?, fallback: String, machineName: String) -> String {
        switch code {
        case "not_found":
            return "That folder doesn't exist on \(machineName). Check the path and try again."
        case "permission_denied":
            return "Codevisor on \(machineName) isn't allowed to read that folder. "
                + "Pick another folder, or adjust its permissions on the machine."
        case "not_a_directory":
            return "That path is a file, not a folder."
        case "invalid_path":
            return "Enter an absolute path (starting with /), or ~ for the home folder."
        default:
            return fallback
        }
    }
}
