import CodevisorCore
import SwiftUI

public struct SandboxSettingsSheets: ViewModifier {
  @Binding var sheet: SandboxSettingsSheet?
  let model: SandboxSettingsModel
  let client: any CodevisorServerClienting
  @State private var addedProvider: ServerSandboxProvider?

  public init(sheet: Binding<SandboxSettingsSheet?>, model: SandboxSettingsModel, client: any CodevisorServerClienting)
  {
    _sheet = sheet
    self.model = model
    self.client = client
  }

  public func body(content: Content) -> some View {
    content.sheet(item: $sheet, onDismiss: addFirstProfile, content: page)
  }

  @ViewBuilder
  private func page(_ sheet: SandboxSettingsSheet) -> some View {
    switch sheet {
    case .newProvider:
      SandboxProviderSheet(model: model, client: client) { addedProvider = $0 }
    case let .editProvider(provider):
      SandboxProviderSheet(model: model, client: client, editing: provider)
    case let .newProfile(provider):
      SandboxNewProfileSheet(model: model, client: client, provider: provider)
    }
  }

  private func addFirstProfile() {
    guard let provider = addedProvider else { return }

    addedProvider = nil
    sheet = .newProfile(provider)
  }
}
