import SwiftUI

struct SandboxSheetError: View {
  let message: String?

  var body: some View {
    if let message {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }
}
