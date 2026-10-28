import SwiftUI

struct ComposerSlimAttachMenu: View {
  let onPhotos: () -> Void
  let onFiles: () -> Void

  var body: some View {
    PullDownMenuButton(
      help: "Attach",
      items: [
        .init(title: "Photos", systemImage: "photo.on.rectangle", action: onPhotos),
        .init(title: "Files", systemImage: "folder", action: onFiles),
      ]
    )
    .overlay {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .semibold))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .frame(width: ComposerSlimCircleButton.diameter, height: ComposerSlimCircleButton.diameter)
    .glassEffect(.regular.interactive(), in: .circle)
    .accessibilityLabel("Attach")
  }
}
