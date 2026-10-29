import CodevisorCore
import SwiftUI

public struct SandboxNewProfileSheet: View {
  @Environment(\.dismiss) private var dismiss
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  @State private var providerId: String?
  @State private var addingProvider: Bool

  public init(model: SandboxSettingsModel, client: any CodevisorServerClienting) {
    self.model = model
    self.client = client
    _providerId = State(initialValue: model.providers.first?.id)
    _addingProvider = State(initialValue: model.providers.isEmpty)
  }

  public var body: some View {
    NavigationStack {
      page
    }
    .environment(\.sandboxSheetCancel, SandboxSheetCancel { dismiss() })
    .sheet(isPresented: $addingProvider, onDismiss: closeWithoutProvider) {
      SandboxProviderSheet(model: model, client: client) { providerId = $0.id }
    }
    #if os(macOS)
      .frame(width: 480, height: 400)
    #endif
  }

  @ViewBuilder
  private var page: some View {
    if let provider = model.provider(providerId), let vendor = model.vendor(provider.vendor) {
      SandboxNewProfilePage(
        model: model, client: client, provider: provider, vendor: vendor, providerId: chosenProvider,
        onNewProvider: { addingProvider = true }, onAdded: { dismiss() })
    } else {
      SandboxSettingsForm(title: "New Profile") {
        Section {
          SandboxProviderPicker(model: model, providerId: chosenProvider) { addingProvider = true }
        }
      }
    }
  }

  private var chosenProvider: Binding<String> {
    Binding(get: { providerId ?? "" }, set: { providerId = $0 })
  }

  private func closeWithoutProvider() {
    guard model.provider(providerId) == nil else { return }

    dismiss()
  }
}
