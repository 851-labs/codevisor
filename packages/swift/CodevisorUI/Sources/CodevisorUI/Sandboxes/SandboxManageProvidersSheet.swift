import CodevisorCore
import SwiftUI

struct SandboxManageProvidersSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var isAdding = false
  @State private var editing: SandboxProviderDraft?
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let onAdded: (ServerSandboxProvider) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if model.providers.isEmpty {
            Text("No Providers")
              .foregroundStyle(.secondary)
          }
          ForEach(model.providers) { provider in
            SandboxProviderRow(title: model.title(of: provider), vendor: provider.vendor) { edit(provider) }
          }
        } footer: {
          #if os(macOS)
            HStack {
              Spacer()
              Button("Add Provider…", systemImage: "plus") { isAdding = true }
            }
          #endif
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Manage Providers")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Add Provider", systemImage: "plus") { isAdding = true }
            .labelStyle(.iconOnly)
          }
        }
      #endif
      #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter {
            Button("Done") { dismiss() }
            .keyboardShortcut(.defaultAction)
          }
        }
      #endif
    }
    #if os(macOS)
      .sheetSize(.step)
    #endif
    .sheet(isPresented: $isAdding) {
      SandboxProviderSheet(draft: SandboxProviderDraft(), model: model, client: client, onSaved: added)
    }
    .sheet(item: $editing) { draft in
      SandboxProviderSheet(draft: draft, model: model, client: client, onSaved: { _ in })
    }
  }

  private func edit(_ provider: ServerSandboxProvider) {
    editing = SandboxProviderDraft(vendor: model.vendor(provider.vendor), provider: provider)
  }

  private func added(_ provider: ServerSandboxProvider) {
    onAdded(provider)
    dismiss()
  }
}
