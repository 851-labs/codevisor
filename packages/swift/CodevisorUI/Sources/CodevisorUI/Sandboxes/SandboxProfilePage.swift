import CodevisorCore
import SwiftUI

struct SandboxProfilePage: View {
  let profile: ServerSandboxProfile
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var draft: SandboxProfileDraft
  @State private var saved: SandboxProfileDraft
  @State private var editedProvider: ServerSandboxProvider?
  @State private var confirmingDelete = false

  init(
    profile: ServerSandboxProfile,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    navigate: @escaping (SandboxSettingsNavigation) -> Void
  ) {
    self.profile = profile
    self.model = model
    self.client = client
    self.navigate = navigate
    let draft = SandboxProfileDraft(profile: profile, vendor: model.vendor(profile.vendor))
    _draft = State(initialValue: draft)
    _saved = State(initialValue: draft)
  }

  var body: some View {
    Form {
      SandboxSheetError(message: model.errorMessage)
      if let vendor = draft.vendor {
        SandboxProfileFields(draft: $draft, vendor: vendor, model: model, onCommit: commit) {
          SandboxDeleteFooter(title: "Delete…", help: "Delete this profile") { confirmingDelete = true }
        }
      }
      if let provider {
        SandboxProfileProviderSection(title: model.title(of: provider)) { editedProvider = provider }
      }
      SandboxDeleteSection(title: "Delete Profile") { confirmingDelete = true }
    }
    .formStyle(.grouped)
    .navigationTitle(profile.name)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onAppear { model.errorMessage = nil }
    .sheet(item: $editedProvider, onDismiss: leaveIfDeleted, content: providerSheet)
    .onChange(of: isDeleted) { leaveIfDeleted() }
    .confirmationDialog("Delete “\(profile.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive, action: delete)
      Button("Cancel", role: .cancel) {}
    }
  }

  private var provider: ServerSandboxProvider? { model.provider(profile.providerId) }

  private var isDeleted: Bool { model.profile(profile.id) == nil }

  private func providerSheet(_ provider: ServerSandboxProvider) -> some View {
    SandboxProviderSheet(model: model, client: client, editing: provider)
  }

  private func leaveIfDeleted() {
    guard isDeleted, editedProvider == nil else { return }

    navigate(.reset(to: nil))
  }

  private func commit() {
    guard draft != saved, draft.canSave else { return }

    let committed = draft
    Task {
      if await model.save(committed, using: client) { saved = committed }
    }
  }

  private func delete() {
    Task { await model.delete(profile, using: client) }
  }
}
