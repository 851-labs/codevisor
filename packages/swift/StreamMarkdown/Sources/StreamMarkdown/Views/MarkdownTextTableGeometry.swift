#if canImport(AppKit)
  import Foundation

  /// TextKit 1 rounds table cells to whole points. Keep the document,
  /// measurement container, and column boundaries on that same grid.
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
        // Rounding cumulative boundaries carries each fractional remainder
        // into the next column instead of losing it once per cell.
        return next - previous
      }
    }
  }
#endif
