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
  let onSaved: (Bot) -> Void

  init(target: BotEditorTarget, environment: AppEnvironment, onSaved: @escaping (Bot) -> Void) {
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
      if editor.editedBot == nil {
        modelSection
        conversationSection
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
    HStack(spacing: 12) {
      Image(systemName: editor.symbolName)
        .font(.system(size: 20))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9, style: .continuous))
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(editor.trimmedName.isEmpty ? "New Bot" : editor.trimmedName)
          .font(.headline)
          .lineLimit(1)
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if editor.isSaving {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.vertical, 4)
  }

  private var subtitle: String {
    if editor.isSaving, editor.editedBot == nil { return "Creating worktrees…" }
    let count = editor.projectCount
    return count == 1 ? "\(editor.machineName) · 1 project" : "\(editor.machineName) · \(count) projects"
  }

  @ViewBuilder
  private var projectsSection: some View {
    Section("Projects") {
      if let bot = editor.editedBot {
        ForEach(bot.record.projects, id: \.projectId) { project in
          LabeledContent {
            Text(project.branch).foregroundStyle(.secondary)
          } label: {
            Label(project.folderName, systemImage: EntitySystemSymbol.projectList)
          }
        }
      } else if editor.eligibleProjects.isEmpty {
        Text("This machine has no git projects yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(editor.selectedProjects) { project in
          HStack {
            Label(project.name, systemImage: EntitySystemSymbol.projectList)
            Spacer()
            Button("Remove \(project.name)", systemImage: "minus.circle.fill") {
              editor.removeProject(project.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(project.name)")
          }
        }
        if !editor.addableProjects.isEmpty {
          Picker(selection: addProjectSelection) {
            Text("Add Project").tag(UUID?.none)
            Divider()
            ForEach(editor.addableProjects) { project in
              Text(project.name).tag(Optional(project.id))
            }
          } label: {
            Text("Add Project").hidden()
          }
          .pickerStyle(.menu)
          .accessibilityLabel("Add Project")
        }
      }
    }
  }

  private var conversationSection: some View {
    Section {
      Toggle("Conversation mode", isOn: $editor.isConversational)
    } footer: {
      Text(
        "Chat with the bot like a messaging app. You see only the messages it sends you, you can message it while it works, and it tells you when its agents finish."
      )
    }
  }

  private var addProjectSelection: Binding<UUID?> {
    Binding(
      get: { nil },
      set: { id in
        if let id { editor.addProject(id) }
      }
    )
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
