import CodevisorCore
import SwiftUI

struct SandboxProfileFields<Footer: View>: View {
  @Binding var draft: SandboxProfileDraft
  let vendor: ServerSandboxVendor
  let model: SandboxSettingsModel
  var onCommit: (() -> Void)?
  @ViewBuilder let footer: () -> Footer

  init(
    draft: Binding<SandboxProfileDraft>,
    vendor: ServerSandboxVendor,
    model: SandboxSettingsModel,
    onCommit: (() -> Void)? = nil,
    @ViewBuilder footer: @escaping () -> Footer
  ) {
    _draft = draft
    self.vendor = vendor
    self.model = model
    self.onCommit = onCommit
    self.footer = footer
  }

  init(draft: Binding<SandboxProfileDraft>, vendor: ServerSandboxVendor, model: SandboxSettingsModel)
  where Footer == EmptyView {
    self.init(draft: draft, vendor: vendor, model: model) { EmptyView() }
  }

  var body: some View {
    Section {
      SandboxTextInput(label: "Name", prompt: "", text: $draft.name, onCommit: onCommit)
      ForEach(vendor.profileFields) { field in
        SandboxFieldRow(
          field: field, draft: $draft.fields, hosts: model.hosts(for: field.capability),
          steps: model.steps(for: field, in: draft), onCommit: onCommit)
      }
    } footer: {
      footer()
    }
  }
}
