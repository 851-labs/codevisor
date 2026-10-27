import CodevisorCore
import SwiftUI

struct SandboxEditorFooter: View {
  let provider: ServerSandboxProviderInfo
  let error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
      if !provider.tested {
        Text(
          "\(provider.displayName) support is built from its documentation and hasn't been tried with a real account yet."
        )
      }
    }
  }
}
