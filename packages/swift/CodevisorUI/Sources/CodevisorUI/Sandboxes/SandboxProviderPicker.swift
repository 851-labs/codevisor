import CodevisorCore
import SwiftUI

struct SandboxProviderPicker: View {
  private static let newProviderTag = "codevisor.new-provider"

  let model: SandboxSettingsModel
  @Binding var providerId: String
  let onNewProvider: () -> Void

  var body: some View {
    Picker("Provider", selection: selection) {
      ForEach(model.providers) { provider in
        Text(model.title(of: provider)).tag(provider.id)
      }
      Divider()
      Text("New Provider…").tag(Self.newProviderTag)
    }
    .pickerStyle(.menu)
  }

  private var selection: Binding<String> {
    Binding(
      get: { providerId },
      set: { chosen in
        if chosen == Self.newProviderTag {
          onNewProvider()
        } else {
          providerId = chosen
        }
      })
  }
}
