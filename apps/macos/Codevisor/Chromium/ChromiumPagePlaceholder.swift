import SwiftUI

struct ChromiumPagePlaceholder: View {
  let snapshot: Data?

  var body: some View {
    Color(nsColor: .textBackgroundColor)
      .overlay(alignment: .topLeading) {
        if let image = snapshot.flatMap(NSImage.init(data:)) {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
        }
      }
      .clipped()
      .accessibilityHidden(true)
  }
}
