import SwiftUI

struct BotsEmptyNewBotButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("New Bot")
        .font(.body.weight(.semibold))
        .padding(.horizontal, 10)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .controlSize(.large)
    .accessibilityIdentifier("sidebar.emptyNewBot")
  }
}
