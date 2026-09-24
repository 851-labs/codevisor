import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Skills pane: one row per skill the fleet carries, with each machine's
/// condition nested beneath. Skills have no enable switch, so a row is the
/// skill and its menu; the machine rows carry the one action that matters —
/// spreading a skill into that machine's harnesses.
struct SkillsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @State private var model = SkillGlobalModel()
  @State private var showingCreate = false
  @State private var showingRemoteImport = false
  @State private var editing: SkillFleetEntry?
  @State private var pendingRemoval: SkillFleetEntry?
  @State private var actionError: String?

  /// Fleet-level skill creation lands on the local machine; the ferry
  /// carries the content everywhere else.
  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      SkillFleetSection(
        model: model,
        onEdit: { editing = $0 },
        onRemove: { pendingRemoval = $0 })
      Section {
        EmptyView()
      } footer: {
        SettingsListActions(message: actionError) {
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
    .settingsPaneFormStyle(theme)
    .background {
      if !theme.isSystem { theme.windowBackground }
    }
    // Skills are plain files that change behind our back (npx skills add,
    // manual edits) — rescan whenever the pane or the fleet changes.
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .sheet(isPresented: $showingCreate) {
      SkillCreateSheet { name, description, pasted in
        do {
          _ = try await localClient.createSkill(
            name: name, description: description, content: pasted)
          actionError = nil
          await model.load(in: environment)
        } catch {
          actionError = ErrorReporter.userFacingMessage(for: error)
          throw error
        }
      }
    }
    .sheet(isPresented: $showingRemoteImport) {
      SkillRemoteImportSheet(
        discover: { try await localClient.discoverRemoteSkills(source: $0) },
        onImport: { source, skillNames in
          do {
            _ = try await localClient.importRemoteSkill(source: source, skillNames: skillNames)
            actionError = nil
            await model.load(in: environment)
          } catch {
            actionError = ErrorReporter.userFacingMessage(for: error)
            throw error
          }
        })
    }
    .sheet(item: $editing) { entry in
      SkillEditorSheet(
        name: entry.name,
        load: { try await localClient.skillContent(directoryName: entry.directoryName) },
        onSave: { content in
          do {
            _ = try await localClient.updateSkill(
              directoryName: entry.directoryName, content: content)
            actionError = nil
            await model.load(in: environment)
          } catch {
            actionError = ErrorReporter.userFacingMessage(for: error)
            throw error
          }
        })
    }
    .confirmationDialog(
      "Remove \(pendingRemoval?.name ?? "skill")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Skill", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await remove(entry) }
      }
      .settingsActionTint(theme)
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
        .settingsActionTint(theme)
    } message: {
      Text("It will be removed from every machine.")
    }
  }

  private func remove(_ entry: SkillFleetEntry) async {
    pendingRemoval = nil
    do {
      _ = try await localClient.removeSkill(directoryName: entry.directoryName)
      actionError = nil
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}

#Preview("Skills") {
  SkillsSettingsView()
    .environment(AppEnvironment.preview())
    .frame(width: 560, height: 460)
}
