import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotEditorSheet: View {
  private struct ModelChoice: Hashable {
    let harnessId: String
    let value: String
  }

  @Environment(\.dismiss) private var dismiss
  @State private var editor: BotEditorModel
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

  var body: some View {
    @Bindable var editor = editor
    Form {
      Section { header }
      Section {
        TextField("Name", text: $editor.name, prompt: Text("Bot name"))
        Picker("Icon", selection: $editor.symbolName) {
          ForEach(BotIcon.choices) { choice in
            Label(choice.title, systemImage: choice.systemImage).tag(choice.systemImage)
          }
        }
        .pickerStyle(.menu)
        Picker("Machine", selection: $editor.serverId) {
          ForEach(editor.machines) { machine in
            Label(machine.name, systemImage: machine.icon.systemImage).tag(machine.id)
          }
        }
        .pickerStyle(.menu)
        .disabled(editor.editedBot != nil)
      }
      projectsSection
      if let bot = editor.editedBot {
        editedBotModelSection(bot)
      } else {
        modelSection
      }
      displaySection
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
        Button(editor.editedBot == nil ? "Create" : "Save") { Task { await save() } }
          .disabled(!editor.canSave)
      }
    }
    .task(id: editor.serverId) { await editor.loadModels() }
    .frame(width: 460)
    .frame(maxHeight: 640)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
  }

  private var header: some View {
    SheetHeaderCard(
      title: editor.trimmedName.isEmpty ? "New Bot" : editor.trimmedName, subtitle: subtitle,
      isWorking: editor.isSaving
    ) {
      Image(systemName: editor.symbolName)
        .font(.system(size: 20))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9, style: .continuous))
        .contentTransition(.symbolEffect(.replace))
    }
  }

  private var subtitle: String {
    if editor.isSaving, editor.editedBot == nil { return "Creating worktrees…" }
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
      } else {
        ForEach(editor.selectedProjects) { project in
          projectRow(project)
        }
      }
    } header: {
      Text("Projects")
    } footer: {
      if editor.canChangeProjects, !editor.addableProjects.isEmpty {
        HStack {
          Spacer()
          Menu("Add Project") {
            ForEach(editor.addableProjects) { project in
              Button(project.name) { Task { await editor.addProject(project.id) } }
            }
          }
          .fixedSize()
        }
      }
    }
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

  private var displaySection: some View {
    Section {
      Picker("Display", selection: $editor.mode) {
        ForEach(BotMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.menu)
    } footer: {
      Text(editor.mode.summary)
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
