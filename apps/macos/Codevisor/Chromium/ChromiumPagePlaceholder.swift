import SwiftUI

struct ChromiumPagePlaceholder: View {
  let snapshot: Data?

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color(nsColor: .textBackgroundColor)
      if let image = snapshot.flatMap(NSImage.init(data:)) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .clipped()
      }
    }
    .accessibilityHidden(true)
  }
}
