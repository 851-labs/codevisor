import SwiftUI

struct ComposerSlimAttachMenu: View {
  static let diameter: CGFloat = 36

  let onPhotos: () -> Void
  let onFiles: () -> Void

  var body: some View {
    ComposerAttachMenu(onPhotos: onPhotos, onFiles: onFiles) {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .semibold))
    }
    .frame(width: Self.diameter, height: Self.diameter)
    .glassEffect(.regular.interactive(), in: .circle)
  }
}
