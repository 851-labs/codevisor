#if canImport(AppKit)
  import Foundation

  enum MarkdownTextTableGeometry {
    static func width(_ proposed: CGFloat) -> CGFloat {
      max(1, proposed).rounded(.up)
    }

    static func columns(_ widths: [CGFloat]) -> [CGFloat] {
      var boundary: CGFloat = 0
      var previous: CGFloat = 0
      return widths.map { width in
        boundary += width
        let next = boundary.rounded()
        defer { previous = next }
        return next - previous
      }
    }
  }
#endif
