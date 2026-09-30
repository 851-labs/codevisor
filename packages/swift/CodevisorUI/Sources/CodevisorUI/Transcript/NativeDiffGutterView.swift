#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import TranscriptKit

  /// The pinned gutter: old and new line numbers and the change marker,
  /// over row tints a shade stronger than the code's so changed lines read
  /// at a glance. The scroll view keeps it at the visible left edge.
  @MainActor
  final class NativeDiffGutterView: NSView {
    weak var textView: NativeDiffTextView?
    private var rows: [LineDiff.Row] = []
    private var metrics = NativeDiffMetrics(rows: [])
    private var colors = NativeDiffColors(theme: .system)

    override var isFlipped: Bool { true }

    func setContent(rows: [LineDiff.Row], metrics: NativeDiffMetrics, colors: NativeDiffColors) {
      self.rows = rows
      self.metrics = metrics
      self.colors = colors
      needsDisplay = true
    }

    // Numbers and markers are chrome: clicks fall through to the text.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
      guard let textView, let range = textView.rowRange(in: dirtyRect) else { return }
      for index in range {
        guard let rowRect = textView.rowRect(at: index), let fill = textView.rowFillRect(at: index) else {
          continue
        }
        let row = rows[index]
        let band = CGRect(x: 0, y: fill.minY, width: bounds.width, height: fill.height)
        colors.gutterBackground.setFill()
        band.fill(using: .sourceOver)
        if let tint = tint(for: row.kind) {
          // Twice the code's tint: the gutter marks the change.
          tint.setFill()
          band.fill(using: .sourceOver)
          band.fill(using: .sourceOver)
        }
        drawGutter(for: row, in: CGRect(x: 0, y: rowRect.minY, width: bounds.width, height: rowRect.height))
      }
    }

    private func tint(for kind: LineDiff.Row.Kind) -> NSColor? {
      switch kind {
      case .context: nil
      case .added: colors.addedBackground
      case .removed: colors.removedBackground
      }
    }

    private func drawGutter(for row: LineDiff.Row, in rowRect: CGRect) {
      let numberColor: NSColor
      switch row.kind {
      case .context: numberColor = colors.lineNumber
      case .added: numberColor = colors.addedForeground
      case .removed: numberColor = colors.removedForeground
      }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: metrics.font,
        .foregroundColor: numberColor,
      ]
      drawRightAligned(
        row.oldLine.map(String.init) ?? "", in: metrics.oldNumberRect(rowRect), attributes: attributes)
      drawRightAligned(
        row.newLine.map(String.init) ?? "", in: metrics.newNumberRect(rowRect), attributes: attributes)

      let marker: String
      let markerColor: NSColor
      switch row.kind {
      case .context:
        return
      case .added:
        marker = "+"
        markerColor = colors.addedForeground
      case .removed:
        marker = "-"
        markerColor = colors.removedForeground
      }
      drawCentered(
        marker,
        in: metrics.markerRect(rowRect),
        attributes: [.font: metrics.font, .foregroundColor: markerColor]
      )
    }

    private func drawRightAligned(
      _ string: String,
      in rect: CGRect,
      attributes: [NSAttributedString.Key: Any]
    ) {
      guard !string.isEmpty else { return }
      let size = (string as NSString).size(withAttributes: attributes)
      let point = CGPoint(
        x: rect.maxX - size.width,
        y: rect.minY + floor((rect.height - size.height) / 2)
      )
      (string as NSString).draw(at: point, withAttributes: attributes)
    }

    private func drawCentered(
      _ string: String,
      in rect: CGRect,
      attributes: [NSAttributedString.Key: Any]
    ) {
      let size = (string as NSString).size(withAttributes: attributes)
      let point = CGPoint(
        x: rect.minX + floor((rect.width - size.width) / 2),
        y: rect.minY + floor((rect.height - size.height) / 2)
      )
      (string as NSString).draw(at: point, withAttributes: attributes)
    }
  }
#endif
