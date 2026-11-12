import SwiftUI

struct MachineDesktopProgress: View {
  let text: String

  var body: some View {
    VStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(16)
  }
}
