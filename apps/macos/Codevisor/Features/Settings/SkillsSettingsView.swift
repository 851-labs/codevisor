import AppKit
import CodevisorCore
import SwiftUI

/// Settings ▸ Skills: global skills in the canonical ~/.agents/skills store
/// (shared across every harness) on top, plus a collapsed section of skills
/// installed directly inside individual harnesses, grouped per harness.
struct SkillsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var scan: ServerSkillsScan?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var actionError: String?
    @State private var showsHarnessSkills = false
    @State private var expandedHarnesses: Set<String> = []
    @State private var showingCreate = false
    @State private var showingRemoteImport = false
    @State private var skillPendingRemoval: ServerGlobalSkill?
    @State private var isMutating = false

    var body: some View {
        content
            .background {
                if !theme.isSystem { theme.windowBackground }
            }
            .task { await reload() }
            .onChange(of: SettingsRouter.shared.selectedTab) { _, tab in
                // Skills are plain files that change behind our back (npx
                // skills add, manual edits) — rescan whenever the tab opens.
                guard tab == .skills else { return }
                Task { await reload() }
            }
            .sheet(isPresented: $showingCreate) {
                SkillCreateSheet { name, description, pasted in
                    try await mutate {
                        try await environment.serverClient.createSkill(
                            name: name,
                            description: description,
                            content: pasted
                        )
                    }
                }
            }
            .sheet(isPresented: $showingRemoteImport) {
                SkillRemoteImportSheet(
                    discover: { source in
                        try await environment.serverClient.discoverRemoteSkills(source: source)
                    },
                    onImport: { source, skillNames in
                        try await mutate {
                            try await environment.serverClient.importRemoteSkill(
                                source: source,
                                skillNames: skillNames
                            )
                        }
                    }
                )
            }
            .confirmationDialog(
                "Remove \(skillPendingRemoval?.name ?? "skill")?",
                isPresented: Binding(
                    get: { skillPendingRemoval != nil },
                    set: { if !$0 { skillPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Skill", role: .destructive) {
                    guard let skill = skillPendingRemoval else { return }
                    Task {
                        try? await mutate {
                            try await environment.serverClient.removeSkill(
                                directoryName: skill.directoryName
                            )
                        }
                    }
                }
                .settingsActionTint(theme)
                Button("Cancel", role: .cancel) { skillPendingRemoval = nil }
                    .settingsActionTint(theme)
            } message: {
                Text("This deletes the skill and removes its links from every harness.")
            }
    }

    private var globalSkills: [ServerGlobalSkill] {
        scan?.global ?? []
    }

    private func isOutOfSync(_ skill: ServerGlobalSkill) -> Bool {
        skill.installs.contains { $0.state == "notInstalled" }
    }

    private func hasConflict(_ skill: ServerGlobalSkill) -> Bool {
        skill.installs.contains { $0.state == "conflict" }
    }

    private var anyOutOfSync: Bool {
        globalSkills.contains(where: isOutOfSync)
    }

    private var brokenLinks: [ServerHarnessSkill] {
        (scan?.harnesses ?? [])
            .flatMap(\.skills)
            .filter { $0.classification == "broken" }
    }

    /// Harness groups that actually have native/independent skills to show.
    private var harnessGroups: [ServerSkillsHarnessGroup] {
        (scan?.harnesses ?? []).filter { !$0.skills.isEmpty }
    }

    private var harnessSkillCount: Int {
        harnessGroups.reduce(0) { $0 + $1.skills.count }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, scan == nil {
            ProgressView()
                .controlSize(.regular)
                .tint(theme.isSystem ? nil : theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading skills")
        } else if let errorMessage, scan == nil {
            ContentUnavailableView {
                Label("Skills Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if globalSkills.isEmpty, harnessGroups.isEmpty {
            emptyState
        } else {
            skillsList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Skills", systemImage: "book.closed")
        } description: {
            Text("Skills are reusable instruction sets shared with your coding agents.")
        } actions: {
            Button {
                showingCreate = true
            } label: {
                Label("New Skill…", systemImage: "plus")
            }
            .settingsActionTint(theme)
            Button("Import Skills…") { showingRemoteImport = true }
                .settingsActionTint(theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    private var skillsList: some View {
        Form {
            if !brokenLinks.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(
                                theme.isSystem
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(theme.statusWarn)
                            )
                            .accessibilityHidden(true)
                        Text(brokenLinksMessage)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button(
                            isMutating ? "Removing\u{2026}" : "Remove All",
                            role: .destructive
                        ) {
                            Task { await removeAllBrokenLinks() }
                        }
                        .settingsActionTint(theme)
                        .disabled(isMutating)
                        .accessibilityLabel("Remove all broken skill links")
                    }
                }
                .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)
            }

            if anyOutOfSync {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                        Text("Some skills aren\u{2019}t available in all of your harnesses.")
                            .foregroundStyle(.primary)
                        Spacer()
                        Button(isMutating ? "Syncing\u{2026}" : "Sync") {
                            Task {
                                try? await mutate {
                                    try await environment.serverClient.syncSkills(directoryNames: nil)
                                }
                            }
                        }
                        .settingsActionTint(theme)
                        .disabled(isMutating)
                    }
                }
                .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)
            }

            Section {
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.isSystem ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
                        .font(.callout)
                }
                ForEach(globalSkills) { skill in
                    globalSkillRow(skill)
                }
            } header: {
                HStack {
                    Text("Global Skills")
                    Spacer()
                    Menu {
                        Button("New Skill…") { showingCreate = true }
                        Button("Import Skills…") { showingRemoteImport = true }
                    } label: {
                        Label("Add Skill", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .settingsActionTint(theme)
                    .menuIndicator(.hidden)
                    .help("New or imported skill")
                }
            }
            .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)

            if !harnessGroups.isEmpty {
                Section {
                    SettingsDisclosureRow(
                        "Installed in your harnesses (\(harnessSkillCount))",
                        isExpanded: $showsHarnessSkills
                    ) {
                        ForEach(harnessGroups) { group in
                            harnessGroupRow(group)
                                .padding(.leading, 17)
                                .padding(.top, 6)
                        }
                    }
                }
                .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)
            }
        }
        .settingsPaneFormStyle(theme)
        .disabled(isMutating)
    }

    private var brokenLinksMessage: String {
        brokenLinks.count == 1
            ? "A broken skill link was found."
            : "\(brokenLinks.count) broken skill links were found."
    }

    private func globalSkillRow(_ skill: ServerGlobalSkill) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skill.invalid == true ? "exclamationmark.triangle" : "book.closed")
                .foregroundStyle(skill.invalid == true ? AnyShapeStyle(theme.statusWarn) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).foregroundStyle(.primary)
                    if skill.invalid == true {
                        skillBadge("Invalid SKILL.md", style: AnyShapeStyle(theme.statusWarn))
                    }
                }
                Text(availabilityText(skill))
                    .font(.caption)
                    .foregroundStyle(
                        hasConflict(skill)
                            ? AnyShapeStyle(theme.statusWarn)
                            : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isOutOfSync(skill) {
                Button("Sync") {
                    Task {
                        try? await mutate {
                            try await environment.serverClient.syncSkills(
                                directoryNames: [skill.directoryName]
                            )
                        }
                    }
                }
                .settingsActionTint(theme)
                .controlSize(.small)
                .disabled(isMutating)
                .help("Make this skill available in all harnesses")
            }
            Menu {
                if FileManager.default.fileExists(atPath: skill.path) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: skill.path)]
                        )
                    }
                }
                Button("Remove…", role: .destructive) { skillPendingRemoval = skill }
            } label: {
                Label("More actions for \(skill.name)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .help(skill.description ?? skill.directoryName)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(skill.name), \(availabilityText(skill))")
    }

    /// One line, one concept: either the skill is everywhere or it isn't.
    private func availabilityText(_ skill: ServerGlobalSkill) -> String {
        if hasConflict(skill) {
            return "Conflicting copy in a harness — see the harness section below"
        }
        return isOutOfSync(skill)
            ? "Not available in all harnesses"
            : "Available in all harnesses"
    }

    private func harnessGroupRow(_ group: ServerSkillsHarnessGroup) -> some View {
        SettingsDisclosureRow(isExpanded: harnessExpansion(group.harnessId)) {
            // The bundled brand glyph, falling back to the catalog symbol.
            HarnessIcon(
                harnessId: group.harnessId,
                fallbackSymbolName: group.harnessSymbol ?? "cpu",
                size: 14
            )
            .frame(width: 16)
            Text("\(group.harnessName) (\(group.skills.count))")
                .foregroundStyle(theme.isSystem ? Color.primary : theme.textPrimary)
        } content: {
            ForEach(group.skills) { skill in
                harnessSkillRow(skill)
                    .padding(.leading, 23)
                    .padding(.top, 6)
            }
        }
    }

    private func harnessExpansion(_ harnessId: String) -> Binding<Bool> {
        Binding(
            get: { expandedHarnesses.contains(harnessId) },
            set: { expanded in
                if expanded {
                    expandedHarnesses.insert(harnessId)
                } else {
                    expandedHarnesses.remove(harnessId)
                }
            }
        )
    }

    private func harnessSkillRow(_ skill: ServerHarnessSkill) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skill.classification == "broken" ? "link.badge.plus" : "book.closed")
                .foregroundStyle(
                    skill.classification == "broken"
                        ? AnyShapeStyle(theme.statusWarn)
                        : AnyShapeStyle(.secondary)
                )
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).foregroundStyle(.primary)
                    if skill.classification == "broken" {
                        skillBadge("Broken link", style: AnyShapeStyle(theme.statusWarn))
                    }
                    if let duplicateOf = skill.duplicateOf {
                        skillBadge("Copy of \(duplicateOf)", style: AnyShapeStyle(.secondary))
                    }
                    if skill.invalid == true {
                        skillBadge("Invalid SKILL.md", style: AnyShapeStyle(theme.statusWarn))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if skill.classification == "independent" {
                Button("Make Global") {
                    Task {
                        try? await mutate {
                            try await environment.serverClient.makeSkillGlobal(
                                harnessId: skill.harnessId,
                                directoryName: skill.directoryName
                            )
                        }
                    }
                }
                .settingsActionTint(theme)
                .controlSize(.small)
                .help("Move into the shared store and link it back")
            }
            Menu {
                if skill.classification == "broken" {
                    Button("Remove Broken Link", role: .destructive) {
                        Task {
                            try? await mutate {
                                try await environment.serverClient.setSkillInstalled(
                                    directoryName: skill.directoryName,
                                    harnessId: skill.harnessId,
                                    installed: false
                                )
                            }
                        }
                    }
                }
                if FileManager.default.fileExists(atPath: skill.path) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: skill.path)]
                        )
                    }
                }
            } label: {
                Label("More actions for \(skill.name)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .help(skill.description ?? abbreviatePath(skill.path))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(skill.name), installed in \(skill.harnessId)")
    }

    private func skillBadge(_ text: String, style: AnyShapeStyle) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
            )
            .foregroundStyle(style)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            scan = try await environment.serverClient.listSkills()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    /// Run one skills mutation: every endpoint returns the full refreshed
    /// scan, so the UI replaces its state wholesale. Failures surface in the
    /// action banner and rethrow so sheets can stay open.
    private func mutate(_ operation: () async throws -> ServerSkillsScan) async throws {
        isMutating = true
        defer { isMutating = false }
        do {
            scan = try await operation()
            actionError = nil
        } catch {
            actionError = ErrorReporter.userFacingMessage(for: error)
            throw error
        }
    }

    private func removeAllBrokenLinks() async {
        let links = brokenLinks
        guard let first = links.first else { return }
        do {
            try await mutate {
                var refreshed = try await environment.serverClient.setSkillInstalled(
                    directoryName: first.directoryName,
                    harnessId: first.harnessId,
                    installed: false
                )
                for link in links.dropFirst() {
                    refreshed = try await environment.serverClient.setSkillInstalled(
                        directoryName: link.directoryName,
                        harnessId: link.harnessId,
                        installed: false
                    )
                }
                return refreshed
            }
        } catch {
            // Earlier removals in the batch may already have succeeded.
            // Refresh so the banner always reflects what remains.
            await reload()
        }
    }
}

/// New-skill form: name + description, and an optional text area for pasting
/// SKILL.md content directly.
private struct SkillCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let onCreate: (String, String, String?) async throws -> Void
    @State private var name = ""
    @State private var skillDescription = ""
    @State private var pastedContent = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("New Skill") {
                    TextField("Name", text: $name, prompt: Text("Deploy checklist"))
                    TextField(
                        "Description",
                        text: $skillDescription,
                        prompt: Text("When to use this skill and what it does"),
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                }
                .listRowBackground(themedFormRowBackground)
                Section("Content") {
                    TextEditor(text: $pastedContent)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Skill content")
                }
                .listRowBackground(themedFormRowBackground)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(theme.statusError)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Creating…" : "Create") {
                    Task { await save() }
                }
                .settingsActionTint(theme)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 460, height: 420)
        .themedSurface(.sheet)
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmed = pastedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            try await onCreate(name, skillDescription, trimmed.isEmpty ? nil : trimmed)
            dismiss()
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

/// Two-stage import: enter a source (GitHub/GitLab repo, git URL, or a site
/// publishing skills), discover what it offers, then import the selection.
private struct SkillRemoteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let discover: (String) async throws -> [ServerRemoteSkillCandidate]
    let onImport: (String, [String]?) async throws -> Void
    @State private var source = ""
    @State private var candidates: [ServerRemoteSkillCandidate]?
    @State private var selection: Set<String> = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Import Skills") {
                    // Same labeled-field pattern as the MCP editor's Server
                    // URL row; verbatim because the LocalizedStringKey
                    // initializer would markdown-link a bare URL prompt.
                    TextField(
                        "Source",
                        text: $source,
                        prompt: Text(verbatim: "https://github.com/vercel-labs/skills")
                    )
                    .onSubmit { Task { await find() } }
                    .disabled(candidates != nil)
                }
                .listRowBackground(themedFormRowBackground)
                if let candidates {
                    Section {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    } header: {
                        HStack {
                            Text("Skills Found (\(candidates.count))")
                            Spacer()
                            let selectable = candidates.filter { !$0.alreadyExists }
                            if !selectable.isEmpty {
                                if selection.count == selectable.count {
                                    Button("Deselect All") { selection = [] }
                                        .buttonStyle(.borderless)
                                        .settingsActionTint(theme)
                                } else {
                                    Button("Select All") {
                                        selection = Set(selectable.map(\.directoryName))
                                    }
                                    .buttonStyle(.borderless)
                                    .settingsActionTint(theme)
                                }
                            }
                        }
                    }
                    .listRowBackground(themedFormRowBackground)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(theme.statusError)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                if candidates != nil {
                    Button("Back") {
                        candidates = nil
                        selection = []
                        errorMessage = nil
                    }
                    .settingsActionTint(theme)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
                if candidates == nil {
                    Button(isWorking ? "Finding…" : "Find Skills") {
                        Task { await find() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                } else {
                    Button(isWorking ? "Importing…" : importLabel) {
                        Task { await runImport() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || isWorking)
                }
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 480, height: candidates == nil ? 220 : 420)
        .themedSurface(.sheet)
    }

    private var importLabel: String {
        selection.count == 1 ? "Import 1 Skill" : "Import \(selection.count) Skills"
    }

    private func candidateRow(_ candidate: ServerRemoteSkillCandidate) -> some View {
        HStack(spacing: 10) {
            if candidate.alreadyExists {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            } else {
                Toggle(
                    candidate.name,
                    isOn: Binding(
                        get: { selection.contains(candidate.directoryName) },
                        set: { included in
                            if included {
                                selection.insert(candidate.directoryName)
                            } else {
                                selection.remove(candidate.directoryName)
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .foregroundStyle(candidate.alreadyExists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let description = candidate.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if candidate.alreadyExists {
                Text("Already added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    private func find() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let found = try await discover(source.trimmingCharacters(in: .whitespaces))
            candidates = found
            // Everything new is pre-selected — one click imports the lot.
            selection = Set(found.filter { !$0.alreadyExists }.map(\.directoryName))
            errorMessage = found.isEmpty ? "No skills found at this source." : nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func runImport() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let names = Array(selection)
            try await onImport(source.trimmingCharacters(in: .whitespaces), names)
            dismiss()
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

#Preview("Skills Settings") {
    SkillsSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
