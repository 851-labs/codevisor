import CodevisorCore
import CodevisorUI
import SwiftUI

struct SkillsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SkillListModel()
  @State private var showingCreate = false
  @State private var showingRemoteImport = false
  @State private var editing: ServerSkill?
  @State private var pendingRemoval: ServerSkill?
  @State private var actionError: String?

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
        }
      }
    }
    .settingsPaneFormStyle()
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
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
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
