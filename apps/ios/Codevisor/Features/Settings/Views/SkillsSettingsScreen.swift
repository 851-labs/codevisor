import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Skills

/// The Skills screen: one row per skill the fleet carries, with each
/// machine's condition nested beneath — the same shared section the Mac
/// renders, so both clients show the same list.
struct SkillsSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SkillGlobalModel()
  @State private var showingCreate = false
  @State private var showingImport = false
  @State private var editing: SkillFleetEntry?
  @State private var pendingRemoval: SkillFleetEntry?
  @State private var actionError: String?

  /// Fleet-level creation lands on the selected machine's server; the ferry
  /// carries the content everywhere else.
  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: environment.machines.selectedMachineId)
  }

  private var localMachineName: String {
    environment.machines.allMachines
      .first { $0.id == environment.machines.selectedMachineId }?.name ?? "this machine"
  }

  var body: some View {
    List {
      SkillFleetSection(
        model: model,
        onEdit: { editing = $0 },
        onRemove: { pendingRemoval = $0 })
    }
    .navigationTitle("Skills")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("New Skill…", systemImage: "plus") { showingCreate = true }
          Button("Import Skills…", systemImage: "square.and.arrow.down") { showingImport = true }
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showingCreate) {
      SkillCreateSheet(machineName: localMachineName) { name, description, pasted in
        _ = try await localClient.createSkill(
          name: name, description: description, content: pasted)
        await model.load(in: environment)
      }
    }
    .sheet(isPresented: $showingImport) {
      SkillImportSheet(
        machineName: localMachineName,
        discover: { try await localClient.discoverRemoteSkills(source: $0) },
        onImport: { source, skillNames in
          _ = try await localClient.importRemoteSkill(source: source, skillNames: skillNames)
          await model.load(in: environment)
        })
    }
    .sheet(item: $editing) { entry in
      SkillEditorSheet(
        name: entry.name,
        load: { try await localClient.skillContent(directoryName: entry.directoryName) },
        onSave: { content in
          _ = try await localClient.updateSkill(
            directoryName: entry.directoryName, content: content)
          await model.load(in: environment)
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
      Text("It will be removed from every machine.")
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

  private func remove(_ entry: SkillFleetEntry) async {
    pendingRemoval = nil
    do {
      _ = try await localClient.removeSkill(directoryName: entry.directoryName)
      await model.load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
