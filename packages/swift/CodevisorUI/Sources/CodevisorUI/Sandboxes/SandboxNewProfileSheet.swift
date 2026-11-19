import CodevisorCore
import SwiftUI

struct SandboxNewProfileSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  let provider: ServerSandboxProvider

  var body: some View {
    stack
      .environment(\.sandboxSheetCancel, SandboxSheetAction { dismiss() })
      .onDisappear { model.errorMessage = nil }
  }

  @ViewBuilder
  private var stack: some View {
    #if os(macOS)
      page
    #else
      NavigationStack { page }
    #endif
  }

  @ViewBuilder
  private var page: some View {
    if let vendor = model.vendor(provider.vendor) {
      SandboxNewProfilePage(model: model, client: client, provider: provider, vendor: vendor) { dismiss() }
    }
  }
}
