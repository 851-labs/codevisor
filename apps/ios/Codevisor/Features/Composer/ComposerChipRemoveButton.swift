import CodevisorUI
import SwiftUI

struct ComposerChipRemoveButton: View {
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: 26, height: 26)
        .background(Circle().fill(.white))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .accessibilityLabel(accessibilityLabel)
  }
}
