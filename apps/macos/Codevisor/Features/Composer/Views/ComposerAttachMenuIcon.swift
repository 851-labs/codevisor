import AppKit

enum ComposerAttachMenuIcon {
  static let photos = icon(systemImage: "photo.on.rectangle")
  static let files = icon(systemImage: "folder")

  private static let canvasSide: CGFloat = 28
  private nonisolated static let glyphPointSize: CGFloat = 16

  private static func icon(systemImage: String) -> NSImage {
    let image = NSImage(size: NSSize(width: canvasSide, height: canvasSide), flipped: false) { rect in
      drawGlyph(systemImage, centeredIn: rect)
      return true
    }
    image.isTemplate = true
    return image
  }

  private nonisolated static func drawGlyph(_ systemImage: String, centeredIn rect: NSRect) {
    let configuration = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
    guard
      let glyph = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { return }

    let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2)
    glyph.draw(in: NSRect(origin: origin, size: glyph.size))
  }
}
