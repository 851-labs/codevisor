import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotEditorSheet: View {
  private static let avatarSize: CGFloat = 64

  private struct ModelChoice: Hashable {
    let harnessId: String
    let value: String
  }

  @Environment(\.dismiss) private var dismiss
  @State private var editor: BotEditorModel
  @State private var showingNewProject = false
  @State private var editsMascot = false
  private let environment: AppEnvironment
  private let store: SessionStore?
  let onSaved: (Bot) -> Void

  init(
    target: BotEditorTarget, environment: AppEnvironment, store: SessionStore?, onSaved: @escaping (Bot) -> Void
  ) {
    self.environment = environment
    self.store = store
    self.onSaved = onSaved
    _editor = State(initialValue: BotEditorModel(target: target, environment: environment))
  }

  private var isCreating: Bool { editor.editedBot == nil }

  var body: some View {
    Form {
      identitySection
      if editor.showsProjects {
        projectsSection
      }
      if let bot = editor.editedBot {
        editedBotModelSection(bot)
      } else {
        modelSection
      }
      if let errorMessage = editor.errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
          .disabled(editor.isSaving)
      }
      ToolbarItem(placement: .confirmationAction) {
        if isCreating, editor.isSaving {
          ProgressView().controlSize(.small)
        } else {
          Button(isCreating ? "Create" : "Save") { Task { await save() } }
            .disabled(!editor.canSave)
        }
      }
    }
    .task(id: editor.serverId) { await editor.loadModels() }
    .task(id: editor.serverId) { await editor.loadMascotOptions() }
    .sheet(isPresented: isShowingProjectSetup) {
      if let setup = editor.projectSetup.setup {
        ProjectSetupSheet(setup: setup)
      }
    }
    .sheet(isPresented: $showingNewProject) {
      NewProjectSheet(serverId: editor.serverId) { project in
        Task { await editor.addNewProject(project) }
      }
      .environment(environment)
    }
    .sheet(isPresented: $editsMascot) { mascotEditor }
    .frame(width: 460)
    .frame(maxHeight: 640)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
  }

  @ViewBuilder
  private var identitySection: some View {
    if isCreating {
      Section {
        identityFields
      } header: {
        BotCreateHeader(editor: editor) { editsMascot = true }
      }
    } else {
      Section { header }
      Section { identityFields }
    }
  }

  @ViewBuilder
  private var identityFields: some View {
    @Bindable var editor = editor
    TextField("Name", text: $editor.name, prompt: Text("Bot name"))
    Picker("Machine", selection: $editor.serverId) {
      ForEach(editor.machines) { machine in
        Label(machine.name, systemImage: machine.icon.systemImage).tag(machine.id)
      }
    }
    .pickerStyle(.menu)
    .disabled(!isCreating)
  }

  private var header: some View {
    SheetHeaderCard(
      title: editor.trimmedName.isEmpty ? "New Bot" : editor.trimmedName, subtitle: subtitle,
      isWorking: editor.isSaving
    ) {
      BotEditableAvatar(editor: editor, size: Self.avatarSize) { editsMascot = true }
    }
  }

  @ViewBuilder
  private var mascotEditor: some View {
    if let mascot = editor.mascot, let options = editor.mascotOptions {
      BotMascotEditorSheet(mascot: mascot, options: options, serverId: editor.serverId) { editor.mascot = $0 }
    }
  }

  private var subtitle: String {
    let count = editor.projectCount
    return count == 1 ? "\(editor.machineName) · 1 project" : "\(editor.machineName) · \(count) projects"
  }

  @ViewBuilder
  private var projectsSection: some View {
    Section {
      if let bot = editor.editedBot, !editor.canChangeProjects {
        ForEach(bot.record.projects, id: \.projectId) { project in
          LabeledContent {
            Text(project.branch).foregroundStyle(.secondary)
          } label: {
            Label(project.folderName, systemImage: EntitySystemSymbol.project)
          }
        }
      } else if editor.eligibleProjects.isEmpty {
        Text("This machine has no git projects yet.")
          .foregroundStyle(.secondary)
      } else if editor.selectedProjects.isEmpty {
        Text("No projects yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(editor.selectedProjects) { project in
          projectRow(project)
        }
      }
    } header: {
      Text("Projects")
    } footer: {
      if editor.canChangeProjects {
        HStack {
          Spacer()
          addProjectMenu
        }
      }
    }
  }

  private var addProjectMenu: some View {
    Menu("Add Project") {
      ForEach(editor.addableProjectGroups) { group in
        Button(group.name) { Task { await editor.addProject(from: group) } }
      }
      Divider()
      Button("New Project…") { showingNewProject = true }
    }
    .fixedSize()
  }

  private var isShowingProjectSetup: Binding<Bool> {
    Binding(
      get: { editor.projectSetup.isPresented },
      set: { presented in
        if !presented { editor.projectSetup.dismiss() }
      }
    )
  }

  private func projectRow(_ project: Project) -> some View {
    HStack {
      Label(project.name, systemImage: EntitySystemSymbol.project)
      Spacer()
      if editor.changingProjectIds.contains(project.id) {
        ProgressView().controlSize(.small)
      } else {
        Button("Remove") {
          Task { await editor.removeProject(project.id) }
        }
        .controlSize(.small)
        .disabled(!editor.canRemoveProject(project.id))
        .help(
          editor.canRemoveProject(project.id)
            ? "Remove \(project.name) from this bot" : "A bot needs at least one project"
        )
        .accessibilityLabel("Remove \(project.name)")
      }
    }
  }

  @ViewBuilder
  private var modelSection: some View {
    Section("Model") {
      if let models = editor.models, !models.harnesses.isEmpty {
        Picker("Model", selection: modelBinding(models)) {
          ForEach(models.harnesses) { harness in
            Section(harness.name) {
              ForEach(harness.models) { model in
                Text(model.name).tag(ModelChoice(harnessId: harness.id, value: model.value))
              }
            }
          }
        }
        .pickerStyle(.menu)
        ForEach(models.parameterOptions) { option in
          Picker(option.name, selection: parameterBinding(option, in: models)) {
            ForEach(option.options) { value in
              Text(value.name).tag(value.value)
            }
          }
          .pickerStyle(.menu)
        }
      } else if editor.models == nil {
        ProgressView().controlSize(.small)
      } else {
        Text("No signed-in harnesses on this machine.")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func editedBotModelSection(_ bot: Bot) -> some View {
    if let controller = sessionController(for: bot) {
      BotSessionModelSection(controller: controller, harnessId: bot.harnessId)
        .task { await controller.connectIfNeeded() }
    }
  }

  private func sessionController(for bot: Bot) -> SessionController? {
    guard let store,
      let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId),
      let project = environment.projectList.projects.first(where: {
        $0.serverId == bot.serverId && $0.id == session.projectId
      })
    else { return nil }
    return store.controller(for: session, project: project)
  }

  private func modelBinding(_ models: BotModelSelection) -> Binding<ModelChoice> {
    Binding(
      get: {
        ModelChoice(harnessId: models.harnessId ?? "", value: models.modelOption?.currentValue ?? "")
      },
      set: { choice in
        Task { await models.chooseModel(harnessId: choice.harnessId, value: choice.value) }
      }
    )
  }

  private func parameterBinding(
    _ option: SessionConfigOption,
    in models: BotModelSelection
  ) -> Binding<String> {
    Binding(
      get: { option.currentValue },
      set: { models.setParameter(option.id, value: $0) }
    )
  }

  private func save() async {
    guard await editor.save() else { return }
    dismiss()
    if let bot = editor.createdBot { onSaved(bot) }
  }
}
