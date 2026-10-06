import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Skills pane: Codevisor's skill store, which agents read through the
/// tool gateway. The store syncs across devices, so the pane reads and
/// writes this Mac's copy.
struct SkillsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @State private var model = SkillListModel()
  @State private var showingCreate = false
  @State private var showingRemoteImport = false
  @State private var editing: ServerSkill?
  @State private var pendingRemoval: ServerSkill?
  @State private var actionError: String?

  /// Changes land on this Mac's store; sync carries them everywhere else.
  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      SkillListSection(
        model: model,
        onEdit: { editing = $0 },
        onRemove: { pendingRemoval = $0 })
      Section {
        EmptyView()
      } footer: {
        SettingsListActions(message: actionError) {
          Menu {
            Button("Add from URL…") { showingRemoteImport = true }
            Button("Add Manually…") { showingCreate = true }
          } label: {
            Label("New Skill", systemImage: "plus")
          }
          .fixedSize()
          .settingsActionTint(theme)
        }
      }
    }
    .settingsPaneFormStyle(theme)
    .background {
      if !theme.isSystem { theme.windowBackground }
    }
    // Reload when another device's change syncs in.
    .task(id: environment.configSync.revisionsByNamespace[ConfigSync.skillsNamespace]) {
      await model.load(client: localClient)
    }
    .sheet(isPresented: $showingCreate) {
      SkillCreateSheet { name, description, pasted in
        do {
          let list = try await localClient.createSkill(
            name: name, description: description, content: pasted)
          actionError = nil
          model.show(list.skills)
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
            let list = try await localClient.importRemoteSkill(
              source: source, skillNames: skillNames)
            actionError = nil
            model.show(list.skills)
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
            let list = try await localClient.updateSkill(
              directoryName: entry.directoryName, content: content)
            actionError = nil
            model.show(list.skills)
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
      Text("It will be removed from every device.")
    }
  }

  private func remove(_ entry: ServerSkill) async {
    pendingRemoval = nil
    do {
      let list = try await localClient.removeSkill(directoryName: entry.directoryName)
      actionError = nil
      model.show(list.skills)
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
