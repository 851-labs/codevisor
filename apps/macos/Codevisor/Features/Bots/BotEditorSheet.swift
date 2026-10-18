import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotEditorSheet: View {
  private struct ModelChoice: Hashable {
    let harnessId: String
    let value: String
  }

  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let target: BotEditorTarget
  let onSaved: (Bot) -> Void
  @State private var name: String
  @State private var symbolName: String
  @State private var serverId: String
  @State private var projectIds: [UUID] = []
  @State private var models: BotModelSelection?
  @State private var isConversational = true
  @State private var isSaving = false
  @State private var didSave = false
  @State private var botId = UUID()
  @State private var errorMessage: String?

  init(target: BotEditorTarget, defaultServerId: String, onSaved: @escaping (Bot) -> Void) {
    self.target = target
    self.onSaved = onSaved
    switch target {
    case .create:
      _name = State(initialValue: "")
      _symbolName = State(initialValue: BotIcon.fallback.systemImage)
      _serverId = State(initialValue: defaultServerId)
    case let .edit(bot):
      _name = State(initialValue: bot.name)
      _symbolName = State(initialValue: bot.symbolName)
      _serverId = State(initialValue: bot.serverId)
    }
  }

  private var editedBot: Bot? {
    if case let .edit(bot) = target { return bot }
    return nil
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var machines: [CodevisorMachine] {
    environment.bots.botMachines
  }

  private var eligibleProjects: [Project] {
    environment.projectList.fleetActiveProjects.filter {
      $0.serverId == serverId && !$0.isScratch && $0.isGitRepository
    }
  }

  private var canSave: Bool {
    guard !trimmedName.isEmpty, !isSaving, !didSave else { return false }
    if editedBot != nil { return true }
    return !selectedProjects.isEmpty && models?.harnessId != nil && models?.isResolving == false
  }

  var body: some View {
    Form {
      Section { header }
      Section {
        TextField("Name", text: $name, prompt: Text("Bot name"))
        Picker("Icon", selection: $symbolName) {
          ForEach(BotIcon.choices) { choice in
            Label(choice.title, systemImage: choice.systemImage).tag(choice.systemImage)
          }
        }
        .pickerStyle(.menu)
        Picker("Machine", selection: $serverId) {
          ForEach(machines) { machine in
            Label(machine.name, systemImage: machine.icon.systemImage).tag(machine.id)
          }
        }
        .pickerStyle(.menu)
        .disabled(editedBot != nil)
      }
      projectsSection
      if editedBot == nil {
        modelSection
        conversationSection
      }
      if let errorMessage {
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
          .disabled(isSaving)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(editedBot == nil ? "Create" : "Save") { Task { await save() } }
          .disabled(!canSave)
      }
    }
    .task(id: serverId) { await loadModels() }
    .onChange(of: serverId) { projectIds = [] }
    .frame(width: 460)
    .frame(maxHeight: 640)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: symbolName)
        .font(.system(size: 20))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9, style: .continuous))
        .contentTransition(.symbolEffect(.replace))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(trimmedName.isEmpty ? "New Bot" : trimmedName)
          .font(.headline)
          .lineLimit(1)
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if isSaving {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.vertical, 4)
  }

  private var subtitle: String {
    if isSaving, editedBot == nil { return "Creating worktrees…" }
    let machine = environment.machines.fleetMachineName(for: serverId) ?? "No machine"
    let count = editedBot?.record.projects.count ?? projectIds.count
    return count == 1 ? "\(machine) · 1 project" : "\(machine) · \(count) projects"
  }

  @ViewBuilder
  private var projectsSection: some View {
    Section("Projects") {
      if let bot = editedBot {
        ForEach(bot.record.projects, id: \.projectId) { project in
          LabeledContent {
            Text(project.branch).foregroundStyle(.secondary)
          } label: {
            Label(project.folderName, systemImage: EntitySystemSymbol.projectList)
          }
        }
      } else if eligibleProjects.isEmpty {
        Text("This machine has no git projects yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(selectedProjects) { project in
          HStack {
            Label(project.name, systemImage: EntitySystemSymbol.projectList)
            Spacer()
            Button("Remove \(project.name)", systemImage: "minus.circle.fill") {
              projectIds.removeAll { $0 == project.id }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(project.name)")
          }
        }
        if !addableProjects.isEmpty {
          Picker(selection: addProjectSelection) {
            Text("Add Project").tag(UUID?.none)
            Divider()
            ForEach(addableProjects) { project in
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
      Toggle("Conversation mode", isOn: $isConversational)
    } footer: {
      Text(
        "Chat with the bot like a messaging app. You see only the messages it sends you, you can message it while it works, and it tells you when its agents finish."
      )
    }
  }

  private var selectedProjects: [Project] {
    projectIds.compactMap { id in eligibleProjects.first { $0.id == id } }
  }

  private var addProjectSelection: Binding<UUID?> {
    Binding(
      get: { nil },
      set: { id in
        if let id { projectIds.append(id) }
      }
    )
  }

  private var addableProjects: [Project] {
    eligibleProjects.filter { !projectIds.contains($0.id) }
  }

  @ViewBuilder
  private var modelSection: some View {
    Section("Model") {
      if let models, !models.harnesses.isEmpty {
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
      } else if models == nil {
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

  private func loadModels() async {
    guard editedBot == nil else { return }
    models = nil
    await environment.warmHarnessCapabilities(for: serverId)
    let selection = BotModelSelection(
      serverId: serverId,
      client: environment.machines.client(for: serverId),
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults
    )
    models = selection
    await selection.seedDefaults()
  }

  private func save() async {
    guard canSave else { return }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      if let bot = editedBot {
        try await environment.bots.update(
          bot, ServerUpdateBotRequest(name: trimmedName, symbolName: symbolName))
        didSave = true
        dismiss()
        return
      }
      guard let models, let harnessId = models.harnessId else { return }
      let request = ServerCreateBotRequest(
        id: botId.uuidString.lowercased(),
        name: trimmedName,
        symbolName: symbolName,
        harnessId: harnessId,
        configSelections: models.configSelections,
        projectIds: selectedProjects.map {
          $0.id.uuidString.lowercased()
        },
        conversational: isConversational
      )
      let bot = try await environment.bots.create(request, on: serverId)
      didSave = true
      dismiss()
      onSaved(bot)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
