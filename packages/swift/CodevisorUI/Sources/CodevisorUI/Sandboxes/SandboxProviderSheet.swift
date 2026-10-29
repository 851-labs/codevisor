import CodevisorCore
import SwiftUI

struct SandboxProviderSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  var editing: ServerSandboxProvider?
  var onAdded: (ServerSandboxProvider) -> Void = { _ in }
  @State private var path: [String] = []

  var body: some View {
    NavigationStack(path: $path) {
      root
        .environment(\.sandboxSheetCancel, cancel)
        .navigationDestination(for: String.self) { vendorId in
          setUp(vendorId).environment(\.sandboxSheetCancel, pushedPageCancel)
        }
    }
    #if os(macOS)
      .frame(width: 480, height: 400)
    #endif
  }

  @ViewBuilder
  private var root: some View {
    if let editing, let vendor = model.vendor(editing.vendor) {
      SandboxEditProviderPage(provider: editing, vendor: vendor, model: model, client: client) { dismiss() }
    } else {
      SandboxVendorChoicePage(model: model) { path.append($0.id) }
    }
  }

  @ViewBuilder
  private func setUp(_ vendorId: String) -> some View {
    if let vendor = model.vendor(vendorId) {
      SandboxNewProviderPage(vendor: vendor, model: model, client: client, onAdded: added)
    }
  }

  private var cancel: SandboxSheetCancel { SandboxSheetCancel { dismiss() } }

  private var pushedPageCancel: SandboxSheetCancel? {
    #if os(macOS)
      cancel
    #else
      nil
    #endif
  }

  private func added(_ provider: ServerSandboxProvider) {
    onAdded(provider)
    dismiss()
  }
}
