import SwiftUI

struct ComposerAttachButton: View {
  private static let diameter: CGFloat = 26

  let onPhotos: () -> Void
  let onFiles: () -> Void
  @State private var isHovered = false

  var body: some View {
    ComposerAttachMenu(onPhotos: onPhotos, onFiles: onFiles) {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(width: Self.diameter, height: Self.diameter)
    .background(Circle().fill(isHovered ? Color.primary.opacity(0.06) : .clear))
    .onHover { isHovered = $0 }
  }
}
