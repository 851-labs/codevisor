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
    #if os(macOS)
      page
        .environment(\.sandboxSheetCancel, cancel)
        .animation(.snappy(duration: 0.2), value: path)
        .onDisappear { model.errorMessage = nil }
    #else
      NavigationStack(path: $path) {
        root
          .environment(\.sandboxSheetCancel, cancel)
          .navigationDestination(for: String.self) { vendorId in
            setUp(vendorId)
          }
      }
      .onDisappear { model.errorMessage = nil }
    #endif
  }

  #if os(macOS)
    @ViewBuilder
    private var page: some View {
      if let vendorId = path.last {
        setUp(vendorId).environment(\.sandboxSheetBack, SandboxSheetAction { path.removeLast() })
      } else {
        root
      }
    }
  #endif

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

  private var cancel: SandboxSheetAction { SandboxSheetAction { dismiss() } }

  private func added(_ provider: ServerSandboxProvider) {
    onAdded(provider)
    dismiss()
  }
}
