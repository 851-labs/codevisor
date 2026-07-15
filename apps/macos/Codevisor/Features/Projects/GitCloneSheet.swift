import SwiftUI
import CodevisorCore

/// Clone a git remote onto the selected machine and register the checkout as
/// a project. Progress streams live from the server's `project.setup` events;
/// failures show classified, actionable guidance instead of raw git stderr.
struct GitCloneSheet: View {
    let client: any CodevisorServerClienting
    let machineName: String
    let onCloned: (Project) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var nameWasEdited = false
    @State private var logLines: [String] = []
    @State private var isCloning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone a repository onto \(machineName)")
                .font(.headline)

            // `prompt:` with `verbatim` keeps the placeholder the normal
            // secondary color; a plain string placeholder that looks like a
            // URL gets auto-detected as a link and rendered in accent blue.
            TextField(
                "Repository URL",
                text: $url,
                prompt: Text(verbatim: "https://github.com/you/project.git")
            )
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .disabled(isCloning)
            .onSubmit { clone() }
            .onChange(of: url) { _, newValue in
                // Auto-fill the name from the repo URL until the user types
                // their own, mirroring the MCP add form.
                if !nameWasEdited { name = Self.derivedName(from: newValue) }
            }

            TextField(
                "Project name",
                text: Binding(get: { name }, set: { name = $0; nameWasEdited = true }),
                prompt: Text("Project name (optional)")
            )
            .textFieldStyle(.roundedBorder)
            .disabled(isCloning)

            if isCloning || !logLines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 140)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: logLines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if isCloning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cloning…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isCloning)
                Button("Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCloning || trimmedUrl.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var trimmedUrl: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repo's basename, sans `.git` — the same name the server derives
    /// when none is supplied ("git@github.com:acme/widget.git" → "widget").
    static func derivedName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
            ? name
            : ""
    }

    private func clone() {
        guard !isCloning, !trimmedUrl.isEmpty else { return }
        isCloning = true
        errorMessage = nil
        logLines = []
        let projectId = UUID()
        let repoUrl = trimmedUrl
        let projectName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            // Best-effort live tail of the clone; the outcome comes from the
            // HTTP response, not from these events.
            let follow = Task {
                do {
                    for try await envelope in client.eventStream(
                        since: ServerSessionTransport.liveOnlyEventCursor
                    ) {
                        if case let .log(_, line) = ProjectSetupEvent.from(
                            envelope, projectId: projectId.uuidString
                        ) {
                            logLines.append(line)
                        }
                    }
                } catch {
                    // Cosmetic stream; a drop just stops the live tail.
                }
            }
            defer { follow.cancel() }
            do {
                let created = try await client.createProjectFromGit(
                    id: projectId,
                    url: repoUrl,
                    name: projectName.isEmpty ? nil : projectName
                )
                let folderPath = created.locations.first?.folderPath ?? ""
                let project = environment.projectList.adoptServerProject(
                    id: UUID(uuidString: created.id) ?? projectId,
                    folderURL: URL(fileURLWithPath: folderPath),
                    name: created.name
                )
                isCloning = false
                onCloned(project)
                dismiss()
            } catch {
                isCloning = false
                errorMessage = Self.guidance(
                    code: serverErrorCode(error),
                    fallback: serverErrorMessage(error)
                )
            }
        }
    }

    /// Actionable messages for classified clone failures. The fallback is the
    /// server's own error sentence.
    static func guidance(code: String?, fallback: String) -> String {
        switch code {
        case "auth_failed":
            return "The machine has no git credentials for this repository. "
                + "Set up SSH keys (or use an HTTPS URL with a token) on the machine, then try again."
        case "repo_not_found":
            return "No repository was found at that URL. Check the address and your access."
        case "network":
            return "The machine couldn't reach the git host. Check its network connection and try again."
        case "disk_full":
            return "The machine is out of disk space."
        case "invalid_url":
            return "That doesn't look like a git repository URL."
        case "already_exists":
            return "A project folder with that name already exists on the machine. "
                + "Add it as a folder instead, or choose a different project name."
        default:
            return fallback
        }
    }
}
