import CodevisorCore
import SwiftUI

struct SandboxProviderMenu: View {
  let title: String
  let providers: [ServerSandboxProviderInfo]
  let onPick: (ServerSandboxProviderInfo) -> Void

  var body: some View {
    Menu(title) {
      ForEach(providers) { provider in
        Button(provider.tested ? provider.displayName : "\(provider.displayName) (untested)") {
          onPick(provider)
        }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(providers.isEmpty)
  }
}
