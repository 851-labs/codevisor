import SwiftUI

struct ComposerAttachMenu<Label: View>: View {
  let onPhotos: () -> Void
  let onFiles: () -> Void
  @ViewBuilder let label: Label

  var body: some View {
    PullDownMenuButton(help: "Attach", items: items)
      .overlay {
        label
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .accessibilityLabel("Attach")
  }

  private var items: [PullDownMenuButton.Item] {
    [
      .init(title: "Photos", image: ComposerAttachMenuIcon.photos, action: onPhotos),
      .init(title: "Files", image: ComposerAttachMenuIcon.files, action: onFiles),
    ]
  }
}
