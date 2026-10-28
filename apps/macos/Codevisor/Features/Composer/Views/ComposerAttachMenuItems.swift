import SwiftUI

struct ComposerAttachMenuItems: View {
  let onPhotos: () -> Void
  let onFiles: () -> Void

  var body: some View {
    Button(action: onPhotos) {
      Label("Photos", systemImage: "photo.on.rectangle")
        .labelStyle(.titleAndIcon)
    }
    Button(action: onFiles) {
      Label("Files", systemImage: "folder")
        .labelStyle(.titleAndIcon)
    }
  }
}
