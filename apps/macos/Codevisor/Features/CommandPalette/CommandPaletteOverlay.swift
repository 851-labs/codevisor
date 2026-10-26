import SwiftUI

struct CommandPaletteOverlay: View {
  let palette: CommandPalette
  let store: SessionStore?

  private static let topInset: CGFloat = 64

  var body: some View {
    if palette.isPresented {
      CommandPalettePanel(palette: palette, store: store)
        .padding(.top, Self.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }
  }
}
