import CodevisorCore
import SwiftUI

struct SandboxEditProfilePage: View {
  let profile: ServerSandboxProfile
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var draft: SandboxProfileDraft
  @State private var status: String?

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
    _draft = State(initialValue: SandboxProfileDraft(profile: profile, vendor: model.vendor(profile.vendor)))
  }

  var body: some View {
    SandboxSettingsForm(
      title: "Edit Profile", actionTitle: "Save", canAct: draft.canSave, status: status,
      errorMessage: model.errorMessage, onAction: save
    ) {
      if let provider = model.provider(profile.providerId) {
        Section {
          SandboxChoiceRow(
            icon: CodevisorSymbol.sandboxVendor(provider.vendor), title: "Provider", detail: model.title(of: provider)
          ) {
            navigate(.push(.editProvider(providerId: provider.id)))
          }
        }
      }
      if let vendor = draft.vendor {
        SandboxProfileFields(draft: $draft, vendor: vendor, model: model)
      }
    }
    .onAppear { model.errorMessage = nil }
  }

  private func save() {
    status = "Saving…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      if saved { navigate(.pop) }
    }
  }
}
