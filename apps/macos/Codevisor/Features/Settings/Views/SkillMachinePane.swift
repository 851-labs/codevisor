import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

/// One machine's skills, rendered on its page: the canonical
/// ~/.agents/skills store as it exists THERE (shared across that machine's
/// harnesses), plus the skills installed directly inside individual
/// harnesses, grouped per harness.
struct SkillMachinePane: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let machine: CodevisorMachine
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

  /// The machine whose skills this pane manages.
  private var serverId: String { machine.id }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: serverId)
  }

  var body: some View {
    Group {
      bannerSections
      // The always-present section carries the pane's lifecycle
      // modifiers exactly once — a Group would apply them per section.
      globalSection
        // Skills are plain files that change behind our back (npx
        // skills add, manual edits) — rescan every time it appears.
        .task(id: serverId) { await reload() }
        .sheet(isPresented: $showingCreate) {
          SkillCreateSheet { name, description, pasted in
            try await mutate {
              try await client.createSkill(
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
              try await client.discoverRemoteSkills(source: source)
            },
            onImport: { source, skillNames in
              try await mutate {
                try await client.importRemoteSkill(
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
                try await client.removeSkill(
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
      harnessInstalledSection
    }
    .disabled(isMutating)
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

  /// Broken-link and out-of-sync banners, each its own quiet section.
  @ViewBuilder
  private var bannerSections: some View {
    if scan != nil, !brokenLinks.isEmpty {
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
    }
    if scan != nil, anyOutOfSync {
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
                try await client.syncSkills(directoryNames: nil)
              }
            }
          }
          .settingsActionTint(theme)
          .disabled(isMutating)
        }
      }
    }
  }

  private var globalSection: some View {
    Section {
      if isLoading, scan == nil {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading…").foregroundStyle(.secondary)
        }
      } else if let errorMessage, scan == nil {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      } else {
        if let actionError {
          Label(actionError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(
              theme.isSystem
                ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn)
            )
            .font(.callout)
        }
        if globalSkills.isEmpty {
          Text("No skills on this machine yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(globalSkills) { skill in
            globalSkillRow(skill)
          }
        }
      }
    } header: {
      Text("Global Skills")
    } footer: {
      // The actions arrive with the list: nothing to add to while the
      // scan is still loading or the machine is unreachable.
      if scan != nil {
        SettingsListActions {
          Button {
            showingCreate = true
          } label: {
            Label("New Skill…", systemImage: "plus")
          }
          .settingsActionTint(theme)
          Button("Import Skills…") { showingRemoteImport = true }
            .settingsActionTint(theme)
        }
      }
    }
  }

  @ViewBuilder
  private var harnessInstalledSection: some View {
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
    }
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
              try await client.syncSkills(
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
}

// MARK: - Harness skills, scanning, and mutations
extension SkillMachinePane {
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
              try await client.makeSkillGlobal(
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
                try await client.setSkillInstalled(
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
      scan = try await client.listSkills()
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
        var refreshed = try await client.setSkillInstalled(
          directoryName: first.directoryName,
          harnessId: first.harnessId,
          installed: false
        )
        for link in links.dropFirst() {
          refreshed = try await client.setSkillInstalled(
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
