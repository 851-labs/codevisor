import CodevisorCore
import SwiftUI

public struct SandboxProviderSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SandboxProviderDraft
  @State private var status: String?
  @State private var isConfirmingRemoval = false
  private let model: SandboxSettingsModel
  private let client: any CodevisorServerClienting
  private let onSaved: (ServerSandboxProvider) -> Void

  public init(
    draft: SandboxProviderDraft,
    model: SandboxSettingsModel,
    client: any CodevisorServerClienting,
    onSaved: @escaping (ServerSandboxProvider) -> Void
  ) {
    _draft = State(initialValue: draft)
    self.model = model
    self.client = client
    self.onSaved = onSaved
  }

  public var body: some View {
    NavigationStack {
      SandboxSheetPage(
        title: draft.isNew ? "Add Provider" : "Edit Provider", confirmTitle: draft.isNew ? "Add Provider" : "Save",
        canConfirm: draft.canSave, status: status, onCancel: { dismiss() }, onConfirm: save
      ) {
        Form {
          SandboxSheetError(message: model.errorMessage)
          Section { vendorRow }
          if let vendor = draft.vendor {
            SandboxProviderFields(draft: $draft, vendor: vendor, model: model)
          }
          if !draft.isNew {
            Section {
              Button("Remove Provider", role: .destructive) { isConfirmingRemoval = true }
            }
          }
        }
        .formStyle(.grouped)
      }
    }
    #if os(macOS)
      .sheetSize(.step)
    #endif
    .interactiveDismissDisabled(status != nil)
    .onAppear { model.errorMessage = nil }
    .alert("Remove this provider?", isPresented: $isConfirmingRemoval) {
      Button("Remove", role: .destructive, action: remove)
      Button("Cancel", role: .cancel) {}
    }
  }

  @ViewBuilder
  private var vendorRow: some View {
    if draft.isNew {
      SandboxSelect(
        label: "Vendor",
        placeholder: "Select a vendor",
        options: model.vendors.vendors.map { vendor in
          .init(id: vendor.id, title: vendor.displayName, systemImage: SandboxVendorSymbol.name(for: vendor.id))
        },
        selection: draft.vendor?.id,
        onSelect: { id in model.vendor(id).map { draft.choose($0) } }
      ) {
        EmptyView()
      }
    } else {
      LabeledContent("Vendor", value: draft.vendor?.displayName ?? "")
    }
  }

  private func save() {
    status = draft.isNew ? "Signing in…" : "Saving…"
    Task {
      let saved = await model.save(draft, using: client)
      status = nil
      guard let saved else { return }
      onSaved(saved)
      dismiss()
    }
  }

  private func remove() {
    guard let provider = model.provider(draft.providerId) else { return }
    status = "Removing…"
    Task {
      let removed = await model.delete(provider, using: client)
      status = nil
      if removed { dismiss() }
    }
  }
}
