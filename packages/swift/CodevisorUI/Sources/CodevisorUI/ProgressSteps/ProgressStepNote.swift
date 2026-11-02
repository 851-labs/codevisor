import SwiftUI

struct ProgressStepNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: ProgressStepList.width)
  }
}
