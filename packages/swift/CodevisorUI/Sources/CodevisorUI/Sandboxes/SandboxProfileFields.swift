import CodevisorCore
import SwiftUI

struct SandboxProfileFields: View {
  @Binding var draft: SandboxProfileDraft
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel

  var body: some View {
    Section {
      SandboxTextInput(label: "Name", prompt: "", text: $draft.name)
      ForEach(vendor.profileFields) { field in
        SandboxFieldRow(
          field: field, draft: $draft.fields, hosts: model.hosts(for: field.capability),
          steps: model.steps(for: field, in: draft))
      }
    }
  }
}
