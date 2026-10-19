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
  @State private var confirmsDelete = false
  @FocusState private var isNameFocused: Bool
  @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 88
  @ScaledMetric(relativeTo: .title2) private var iconChoiceSize: CGFloat = 44
  let onCreated: (Bot) -> Void
  let onDelete: (Bot) -> Void

  init(
    target: BotEditorTarget,
    environment: AppEnvironment,
    onCreated: @escaping (Bot) -> Void,
    onDelete: @escaping (Bot) -> Void
  ) {
    self.onCreated = onCreated
    self.onDelete = onDelete
    _editor = State(initialValue: BotEditorModel(target: target, environment: environment))
  }

  private var isCreating: Bool { editor.editedBot == nil }

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        iconSection
        if isCreating {
          machineSection
        }
        projectsSection
        if isCreating {
          modelSection
          conversationSection
        }
        if let bot = editor.editedBot {
          deleteSection(bot)
        }
        if let errorMessage = editor.errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
      }
      .navigationTitle(isCreating ? "New Bot" : "Edit Bot")
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
            Button(isCreating ? "Create" : "Done", role: .confirm) { Task { await save() } }
              .disabled(!editor.canSave)
              .accessibilityIdentifier("botEditor.save")
          }
        }
      }
      .disabled(editor.isSaving)
      .interactiveDismissDisabled(editor.isSaving)
      .task(id: editor.serverId) { await editor.loadModels() }
      .onAppear { if isCreating { isNameFocused = true } }
    }
  }

  private func deleteSection(_ bot: Bot) -> some View {
    Section {
      Button("Delete Bot", role: .destructive) { confirmsDelete = true }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
          "Delete \(bot.name)?", isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
          Button("Delete Bot", role: .destructive) {
            dismiss()
            onDelete(bot)
          }
        } message: {
          Text(environment.botDeletionMessage(for: bot))
        }
    }
  }

  private var identitySection: some View {
    Section {
      VStack(spacing: 16) {
        BotAvatar(symbolName: editor.symbolName, size: iconSize)
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

  private var iconSection: some View {
    Section {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: iconChoiceSize), spacing: 12)], spacing: 12) {
        ForEach(BotIcon.choices) { choice in
          iconChoice(choice)
        }
      }
      .padding(.vertical, 6)
    }
  }

  private func iconChoice(_ choice: BotIcon) -> some View {
    let isSelected = editor.symbolName == choice.systemImage
    return Button {
      editor.symbolName = choice.systemImage
    } label: {
      Image(systemName: choice.systemImage)
        .font(.system(size: iconChoiceSize * 0.42))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .frame(width: iconChoiceSize, height: iconChoiceSize)
        .background(
          isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
          in: .circle
        )
        .overlay {
          Circle()
            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 3)
            .padding(-5)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(choice.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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

  @ViewBuilder
  private var projectsSection: some View {
    if let bot = editor.editedBot, !editor.canChangeProjects {
      Section("Projects") {
        ForEach(bot.record.projects, id: \.projectId) { project in
          LabeledContent {
            Text(project.branch)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } label: {
            projectLabel(project.folderName)
          }
        }
      }
    } else {
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
        } else if !editor.addableProjects.isEmpty {
          Menu {
            ForEach(editor.addableProjects) { project in
              Button(project.name) { Task { await editor.addProject(project.id) } }
            }
          } label: {
            Label("Add Project", systemImage: "folder.badge.plus")
          }
          .accessibilityIdentifier("botEditor.addProject")
        }
      }
    }
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

  private var conversationSection: some View {
    Section {
      Toggle("Conversation Mode", isOn: $editor.isConversational)
    } footer: {
      Text(
        "Chat with the bot like a messaging app. You see only the messages it sends you, you can message it while it works, and it tells you when its agents finish."
      )
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
