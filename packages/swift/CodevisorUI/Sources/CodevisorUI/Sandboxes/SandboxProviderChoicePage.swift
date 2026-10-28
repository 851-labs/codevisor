import CodevisorCore
import SwiftUI

struct SandboxProviderChoicePage: View {
  let model: SandboxSettingsModel
  let navigate: (SandboxSettingsNavigation) -> Void

  var body: some View {
    SandboxSettingsForm(title: "Choose a Provider") {
      Section {
        ForEach(model.providers) { provider in
          SandboxChoiceRow(icon: CodevisorSymbol.sandboxVendor(provider.vendor), title: model.title(of: provider)) {
            navigate(.push(.newProfile(providerId: provider.id)))
          }
        }
      }
      Section {
        SandboxChoiceRow(icon: Image(systemName: "plus"), title: "New Provider") {
          navigate(.push(.vendors))
        }
      }
    }
  }
}
