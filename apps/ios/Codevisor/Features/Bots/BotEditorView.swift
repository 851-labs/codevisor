import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotEditorView: View {
  private struct ModelChoice: Hashable {
    let harnessId: String
    let value: String
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(AppEnvironment.self) private var environment
  @State private var editor: BotEditorModel
  @State private var showingNewProject = false
  @State private var editsMascot = false
  @FocusState private var isNameFocused: Bool
  @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 88
  let onCreated: (Bot) -> Void
  let onArchive: (Bot) -> Void

  init(
    target: BotEditorTarget,
    environment: AppEnvironment,
    onCreated: @escaping (Bot) -> Void,
    onArchive: @escaping (Bot) -> Void
  ) {
    self.onCreated = onCreated
    self.onArchive = onArchive
    _editor = State(initialValue: BotEditorModel(target: target, environment: environment))
  }

  private var isCreating: Bool { editor.editedBot == nil }

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        if editor.canChangeMachine {
          machineSection
        }
        if editor.showsProjects {
          projectsSection
        }
        if let bot = editor.editedBot {
          editedBotModelSection(bot)
          archiveSection(bot)
        } else {
          modelSection
        }
        if editor.forkedBot != nil {
          agentsSection
        }
        if let errorMessage = editor.errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
      }
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
            .disabled(editor.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if editor.isSaving {
            ProgressView()
          } else {
            Button(confirmTitle, role: .confirm) { Task { await save() } }
              .disabled(!editor.canSave)
              .accessibilityIdentifier("botEditor.save")
          }
        }
      }
      .disabled(editor.isSaving)
      .interactiveDismissDisabled(editor.isSaving)
      .task(id: editor.modelCatalogKey) { await editor.loadModels() }
      .task(id: editor.serverId) { await editor.loadMascotOptions() }
      .sheet(isPresented: isShowingProjectSetup) {
        if let setup = editor.projectSetup.setup {
          ProjectSetupScreen(setup: setup)
        }
      }
      .sheet(isPresented: $showingNewProject) {
        ManageProjectsSheet(serverId: editor.serverId, onDeleted: { _ in }) { project in
          Task { await editor.addNewProject(project) }
        }
      }
      .fullScreenCover(isPresented: $editsMascot) { mascotEditor }
      .onAppear { if isCreating { isNameFocused = true } }
    }
  }

  @ViewBuilder
  private var mascotEditor: some View {
    if let mascot = editor.mascot, let options = editor.mascotOptions {
      BotMascotEditorScreen(mascot: mascot, options: options, serverId: editor.serverId) { editor.mascot = $0 }
    }
  }

  private func archiveSection(_ bot: Bot) -> some View {
    Section {
      Button("Archive Bot", systemImage: "archivebox") {
        dismiss()
        onArchive(bot)
      }
      .frame(maxWidth: .infinity)
    }
  }

  private var identitySection: some View {
    Section {
      VStack(spacing: 16) {
        BotIdentityAvatar(editor: editor, size: iconSize) { editsMascot = true }
        TextField("Bot Name", text: $editor.name)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
          .textInputAutocapitalization(.words)
          .submitLabel(.done)
          .focused($isNameFocused)
          .padding(.vertical, 12)
          .padding(.horizontal, 16)
          .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
          .accessibilityIdentifier("botEditor.name")
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
  }

  private var navigationTitle: String {
    if editor.forkedBot != nil { return "Fork Bot" }
    return isCreating ? "New Bot" : "Edit Bot"
  }

  private var confirmTitle: String {
    if editor.forkedBot != nil { return "Fork" }
    return isCreating ? "Create" : "Done"
  }

  private var agentsSection: some View {
    Section {
      Toggle("Transfer All Agents", isOn: $editor.movesAgents)
    } header: {
      Text("Agents")
    } footer: {
      Text(editor.transferAgentsDetail)
    }
  }

  private var machineSection: some View {
    Section {
      Picker("Machine", selection: $editor.serverId) {
        ForEach(editor.machines) { machine in
          Label(machine.name, systemImage: machine.icon.systemImage).tag(machine.id)
        }
      }
    }
  }

  private var projectsSection: some View {
    Section("Projects") {
      ForEach(editor.selectedProjects) { project in
        LabeledContent {
          if editor.changingProjectIds.contains(project.id) {
            ProgressView()
          }
        } label: {
          projectLabel(project.name)
        }
        .deleteDisabled(!editor.canRemoveProject(project.id))
      }
      .onDelete { offsets in
        let projects = offsets.map { editor.selectedProjects[$0] }
        Task {
          for project in projects {
            await editor.removeProject(project.id)
          }
        }
      }
      if editor.eligibleProjects.isEmpty {
        Text("This machine has no git projects yet.")
          .foregroundStyle(.secondary)
      }
      addProjectMenu
    }
  }

  private var addProjectMenu: some View {
    Menu {
      ForEach(editor.addableProjectGroups) { group in
        Button(group.name) { Task { await editor.addProject(from: group) } }
      }
      Divider()
      Button("New Project…") { showingNewProject = true }
    } label: {
      Label("Add Project", systemImage: "folder.badge.plus")
    }
    .accessibilityIdentifier("botEditor.addProject")
  }

  private var isShowingProjectSetup: Binding<Bool> {
    Binding(
      get: { editor.projectSetup.isPresented },
      set: { presented in
        if !presented { editor.projectSetup.dismiss() }
      }
    )
  }

  private func projectLabel(_ name: String) -> some View {
    Label {
      Text(name)
    } icon: {
      Image(systemName: EntitySystemSymbol.project)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var modelSection: some View {
    Section {
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
        .pickerStyle(.navigationLink)
        ForEach(models.parameterOptions) { option in
          Picker(option.name, selection: parameterBinding(option, in: models)) {
            ForEach(option.options) { value in
              Text(value.name).tag(value.value)
            }
          }
          .pickerStyle(.navigationLink)
        }
      } else if editor.models == nil {
        HStack {
          Text("Loading Models…")
            .foregroundStyle(.secondary)
          Spacer()
          ProgressView()
        }
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
    guard let session = environment.projectList.session(bot.sessionId, serverId: bot.serverId),
      let project = environment.projectList.projects.first(where: {
        $0.serverId == bot.serverId && $0.id == session.projectId
      })
    else { return nil }
    return ChatControllerCache.shared.controller(
      for: session, project: project, workspaceId: bot.workspaceId, environment: environment)
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

  private func parameterBinding(_ option: SessionConfigOption, in models: BotModelSelection) -> Binding<String> {
    Binding(
      get: { option.currentValue },
      set: { models.setParameter(option.id, value: $0) }
    )
  }

  private func save() async {
    guard await editor.save() else { return }
    dismiss()
    if let bot = editor.createdBot { onCreated(bot) }
  }
}
