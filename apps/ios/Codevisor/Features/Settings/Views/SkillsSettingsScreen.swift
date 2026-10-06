import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Skills

/// The Skills screen: Codevisor's skill store, the same shared section the
/// Mac renders. The store syncs across devices, so the screen reads and
/// writes the selected machine's copy.
struct SkillsSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SkillListModel()
  @State private var showingCreate = false
  @State private var showingImport = false
  @State private var editing: ServerSkill?
  @State private var pendingRemoval: ServerSkill?
  @State private var actionError: String?

  /// Changes land on the selected machine's store; sync carries them
  /// everywhere else.
  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: environment.machines.selectedMachineId)
  }

  private var localMachineName: String {
    environment.machines.allMachines
      .first { $0.id == environment.machines.selectedMachineId }?.name ?? "this machine"
  }

  var body: some View {
    List {
      SkillListSection(
        model: model,
        onEdit: { editing = $0 },
        onRemove: { pendingRemoval = $0 })
    }
    .navigationTitle("Skills")
    .navigationBarTitleDisplayMode(.inline)
    // Reload when the machine changes or another device's change syncs in.
    .task(
      id: ReloadKey(
        machineId: environment.machines.selectedMachineId,
        revision: environment.configSync.revisionsByNamespace[ConfigSync.skillsNamespace]
      )
    ) {
      await model.load(client: localClient)
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Add from URL…", systemImage: "link") { showingImport = true }
          Button("Add Manually…", systemImage: "square.and.pencil") { showingCreate = true }
        } label: {
          Label("New Skill", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showingCreate) {
      SkillCreateSheet(machineName: localMachineName) { name, description, pasted in
        let list = try await localClient.createSkill(
          name: name, description: description, content: pasted)
        model.show(list.skills)
      }
    }
    .sheet(isPresented: $showingImport) {
      SkillImportSheet(
        machineName: localMachineName,
        discover: { try await localClient.discoverRemoteSkills(source: $0) },
        onImport: { source, skillNames in
          let list = try await localClient.importRemoteSkill(source: source, skillNames: skillNames)
          model.show(list.skills)
        })
    }
    .sheet(item: $editing) { entry in
      SkillEditorSheet(
        name: entry.name,
        load: { try await localClient.skillContent(directoryName: entry.directoryName) },
        onSave: { content in
          let list = try await localClient.updateSkill(
            directoryName: entry.directoryName, content: content)
          model.show(list.skills)
        })
    }
    .alert(
      "Remove \(pendingRemoval?.name ?? "skill")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    ) {
      Button("Remove", role: .destructive) {
        guard let entry = pendingRemoval else { return }
        Task { await remove(entry) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("It will be removed from every device.")
    }
    .alert(
      "Couldn’t update skills",
      isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    ) {
      Button("OK", role: .cancel) { actionError = nil }
    } message: {
      Text(actionError ?? "")
    }
  }

  private func remove(_ entry: ServerSkill) async {
    pendingRemoval = nil
    do {
      let list = try await localClient.removeSkill(directoryName: entry.directoryName)
      model.show(list.skills)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private struct ReloadKey: Equatable {
    var machineId: String
    var revision: UInt64?
  }
}
