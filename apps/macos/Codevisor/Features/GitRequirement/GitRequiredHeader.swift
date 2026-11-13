import SwiftUI

struct GitRequiredHeader: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "hammer")
        .font(.system(size: 30, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Codevisor Needs Apple's Developer Tools")
          .font(.title3.weight(.semibold))
        Text("They include Git, which Codevisor uses to work with your projects.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
