import SwiftUI

struct HomeComposeOverlayButton: View {
  let image: Image
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      image
        .font(.title3)
        .foregroundStyle(.white)
        .padding(13)
        .background(Circle().fill(Color.accentColor))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .padding([.trailing, .bottom], 16)
  }
}
