import CodevisorCore
import CodevisorUI
import SwiftUI

struct SkillMachineScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let machine: CodevisorMachine
  let title: String

  @State private var scan: ServerSkillsScan?
  @State private var isLoading = true
  @State private var isMutating = false
  @State private var errorMessage: String?
  @State private var activeSheet: SkillSheet?
  @State private var loadRevision = 0

  private enum SkillSheet: Identifiable {
    case create
    case importSkills
    case edit(ServerGlobalSkill)

    var id: String {
      switch self {
      case .create: "create"
      case .importSkills: "import"
      case .edit(let skill): "edit:\(skill.id)"
      }
    }
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machine.id)
  }

  private var actionsDisabled: Bool {
    isMutating || scan == nil || environment.machines.statusByMachineId[machine.id]?.isReachable == false
  }

  var body: some View {
    List {
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red)
        if scan == nil, !isLoading {
          Button("Retry") { Task { await load() } }
        }
      }
      if isLoading, scan == nil {
        HStack {
          Spacer(); ProgressView(); Spacer()
        }
      } else if let scan {
        if scan.global.isEmpty {
          Text("No skills on this machine yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(scan.global) { skill in
            skillRow(skill)
          }
        }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("New Skill", systemImage: "square.and.pencil") { activeSheet = .create }
          Button("Import Skill", systemImage: "square.and.arrow.down") { activeSheet = .importSkills }
        } label: {
          Label("Add Skill", systemImage: "plus")
        }
        .disabled(actionsDisabled)
      }
    }
    .task(id: machine.id) { await load() }
    .onChange(of: environment.configSync.revisionsByNamespace["skills"]) { _, _ in
      Task { await load() }
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .create:
        SkillCreateSheet(machineName: machine.name) { name, description, content in
          try await mutate {
            try await client.createSkill(name: name, description: description, content: content)
          }
        }
      case .importSkills:
        SkillImportSheet(
          machineName: machine.name,
          discover: { try await client.discoverRemoteSkills(source: $0) },
          onImport: { source, names in
            try await mutate {
              try await client.importRemoteSkill(source: source, skillNames: names)
            }
          }
        )
      case .edit(let skill):
        SkillEditSheet(
          skill: skill,
          machineName: machine.name,
          loadContent: { try await client.skillContent(directoryName: skill.directoryName) },
          onSave: { content in
            try await mutate {
              try await client.updateSkill(directoryName: skill.directoryName, content: content)
            }
          }
        )
      }
    }
  }

  private func skillRow(_ skill: ServerGlobalSkill) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(skill.name)
      if let description = skill.description, !description.isEmpty {
        Text(description)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(role: .destructive) {
        Task {
          try? await mutate { try await client.removeSkill(directoryName: skill.directoryName) }
        }
      } label: {
        Image(systemName: "trash")
      }
      .accessibilityLabel("Remove \(skill.name)")
      .disabled(actionsDisabled)
      Button {
        activeSheet = .edit(skill)
      } label: {
        Image(systemName: "pencil")
      }
      .accessibilityLabel("Edit \(skill.name)")
      .tint(.blue)
      .disabled(actionsDisabled)
    }
  }

  private func load() async {
    guard !isMutating else { return }
    loadRevision += 1
    let revision = loadRevision
    isLoading = true
    defer { isLoading = false }
    do {
      let refreshed = try await client.listSkills()
      guard revision == loadRevision else { return }
      scan = refreshed
      errorMessage = nil
    } catch {
      guard revision == loadRevision, !isTaskCancellation(error) else { return }
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func mutate(_ operation: () async throws -> ServerSkillsScan) async throws {
    loadRevision += 1
    isMutating = true
    defer { isMutating = false }
    do {
      scan = try await operation()
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      throw error
    }
  }
}
