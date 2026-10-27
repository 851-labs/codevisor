import CodevisorCore
import SwiftUI

struct SandboxAddMenu: View {
  let title: String
  let providers: [ServerSandboxProviderInfo]
  let onPick: (ServerSandboxProviderInfo) -> Void
  @State private var isChoosing = false

  var body: some View {
    Button {
      isChoosing = true
    } label: {
      Label(title, systemImage: "plus")
    }
    .disabled(providers.isEmpty)
    .confirmationDialog(title, isPresented: $isChoosing, titleVisibility: .visible) {
      ForEach(providers) { provider in
        Button(provider.tested ? provider.displayName : "\(provider.displayName) (untested)") {
          onPick(provider)
        }
      }
    }
  }
}
