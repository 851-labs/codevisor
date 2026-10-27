import SwiftUI

struct ComposerSlimAttachMenu: View {
  let onPhotos: () -> Void
  let onFiles: () -> Void

  var body: some View {
    Menu {
      Button(action: onPhotos) {
        Label("Photos", systemImage: "photo.on.rectangle")
          .labelStyle(.titleAndIcon)
      }
      Button(action: onFiles) {
        Label("Files", systemImage: "folder")
          .labelStyle(.titleAndIcon)
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .semibold))
        .frame(width: ComposerSlimCircleButton.diameter, height: ComposerSlimCircleButton.diameter)
        .contentShape(.circle)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .glassEffect(.regular.interactive(), in: .circle)
    .help("Attach")
    .accessibilityLabel("Attach")
  }
}
