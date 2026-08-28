import CodevisorCore
import SwiftUI

/// Clones a git remote on a target machine and adopts it as a project. The
/// operation is shared, while each platform keeps native sheet structure:
/// a compact dialog form on macOS and a navigation form on iOS.
public struct GitCloneSheet: View {
    let client: any CodevisorServerClienting
    let machineName: String
    let serverId: String?
    let onCloned: (Project) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var nameWasEdited = false
    @State private var logLines: [String] = []
    @State private var isCloning = false
    @State private var errorMessage: String?

    public init(
        client: any CodevisorServerClienting,
        machineName: String,
        serverId: String? = nil,
        onCloned: @escaping (Project) -> Void
    ) {
        self.client = client
        self.machineName = machineName
        self.serverId = serverId
        self.onCloned = onCloned
    }

    public var body: some View {
        #if os(iOS)
            NavigationStack {
                Form {
                    Section("Repository") {
                        repositoryFields
                    }
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("Clone Repository")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isCloning)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: clone) {
                            ZStack {
                                Text("Clone")
                                    .opacity(isCloning ? 0 : 1)
                                if isCloning {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isCloning || trimmedUrl.isEmpty)
                        .accessibilityLabel(isCloning ? "Cloning Repository" : "Clone")
                    }
                }
            }
            .interactiveDismissDisabled(isCloning)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
            VStack(alignment: .leading, spacing: 12) {
                Text("Clone Repository")
                    .font(.headline)
                repositoryFields
                    .textFieldStyle(.roundedBorder)
                if isCloning || !logLines.isEmpty { cloneLog }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    if isCloning {
                        ProgressView().controlSize(.small)
                        Text("Cloning…").foregroundStyle(.secondary)
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
            .interactiveDismissDisabled(isCloning)
        #endif
    }

    private var repositoryFields: some View {
        Group {
            #if os(iOS)
                repositoryURLField
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
            #else
                repositoryURLField
            #endif

            TextField(
                "Project Name (Optional)",
                text: Binding(
                    get: { name },
                    set: {
                        name = $0
                        nameWasEdited = true
                    }
                ),
                prompt: Text("Project Name (Optional)")
            )
            .disabled(isCloning)
        }
    }

    private var repositoryURLField: some View {
        TextField(
            "Repository URL",
            text: $url,
            prompt: Text(verbatim: "https://github.com/you/project.git")
        )
        .font(.body.monospaced())
        .disabled(isCloning)
        .onSubmit { clone() }
        .onChange(of: url) { _, newValue in
            if !nameWasEdited { name = Self.derivedName(from: newValue) }
        }
    }

    private var cloneLog: some View {
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
            }
            .frame(minHeight: 100, maxHeight: 180)
            .onChange(of: logLines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var trimmedUrl: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            let follow = Task {
                do {
                    for try await envelope in client.eventStream(
                        since: ServerSessionTransport.liveOnlyEventCursor
                    ) {
                        if case let .log(_, line) = ProjectSetupEvent.from(
                            envelope,
                            projectId: projectId.uuidString
                        ) {
                            logLines.append(line)
                        }
                    }
                } catch {
                    // The event stream is cosmetic; the HTTP response owns the
                    // operation's actual success or failure.
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
                    name: created.name,
                    serverId: serverId
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

    static func guidance(code: String?, fallback: String) -> String {
        switch code {
        case "auth_failed":
            "The machine has no git credentials for this repository. "
                + "Set up SSH keys (or use an HTTPS URL with a token) on the machine, then try again."
        case "repo_not_found":
            "No repository was found at that URL. Check the address and your access."
        case "network":
            "The machine couldn't reach the git host. Check its network connection and try again."
        case "disk_full":
            "The machine is out of disk space."
        case "invalid_url":
            "That doesn't look like a git repository URL."
        case "already_exists":
            "A project folder with that name already exists on the machine. "
                + "Add it as a folder instead, or choose a different project name."
        default:
            fallback
        }
    }
}
