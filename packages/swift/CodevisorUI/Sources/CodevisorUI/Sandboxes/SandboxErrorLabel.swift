import SwiftUI

struct SandboxErrorLabel: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.callout)
      .foregroundStyle(.red)
      .fixedSize(horizontal: false, vertical: true)
  }
}
