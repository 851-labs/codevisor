import SwiftUI

struct SandboxSheetError: View {
  let message: String?

  var body: some View {
    if let message {
      Section {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      }
    }
  }
}
