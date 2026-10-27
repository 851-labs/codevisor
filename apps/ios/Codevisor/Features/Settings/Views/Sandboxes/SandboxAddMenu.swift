import CodevisorCore
import SwiftUI

struct SandboxAddMenu: View {
  let title: String
  let providers: [ServerSandboxProviderInfo]
  let onPick: (ServerSandboxProviderInfo) -> Void

  var body: some View {
    Menu {
      ForEach(providers) { provider in
        Button(provider.tested ? provider.displayName : "\(provider.displayName) (untested)") {
          onPick(provider)
        }
      }
    } label: {
      Label(title, systemImage: "plus")
    }
    .disabled(providers.isEmpty)
  }
}
