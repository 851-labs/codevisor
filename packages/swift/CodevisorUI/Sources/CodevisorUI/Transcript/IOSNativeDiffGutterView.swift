#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI
  import TranscriptKit
  import UIKit

  /// The pinned gutter: one line-number column (the new line, or the old
  /// one for a removed line) and the change marker, over row tints a shade
  /// stronger than the code's so changed lines read at a glance.
  @MainActor
  final class IOSNativeDiffGutterView: UIView {
    weak var textView: IOSNativeDiffTextView?
    private var rows: [LineDiff.Row] = []
    private var metrics = IOSNativeDiffMetrics(rows: [])
    private var colors = IOSNativeDiffColors(theme: .system)

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      isOpaque = false
      isUserInteractionEnabled = false
      contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func setContent(rows: [LineDiff.Row], metrics: IOSNativeDiffMetrics, colors: IOSNativeDiffColors) {
      self.rows = rows
      self.metrics = metrics
      self.colors = colors
      setNeedsDisplay()
    }

    override func draw(_ dirtyRect: CGRect) {
      guard let textView, let range = textView.rowRange(in: dirtyRect) else { return }
      for index in range {
        guard let rowRect = textView.rowRect(at: index), let fill = textView.rowFillRect(at: index) else {
          continue
        }
        let row = rows[index]
        let band = CGRect(x: 0, y: fill.minY, width: bounds.width, height: fill.height)
        colors.gutterBackground.setFill()
        UIRectFill(band)
        if let tint = tint(for: row.kind) {
          // Twice the code's tint: the gutter marks the change.
          tint.setFill()
          UIRectFillUsingBlendMode(band, .normal)
          UIRectFillUsingBlendMode(band, .normal)
        }
        drawGutter(for: row, in: CGRect(x: 0, y: rowRect.minY, width: bounds.width, height: rowRect.height))
      }
    }

    private func tint(for kind: LineDiff.Row.Kind) -> UIColor? {
      switch kind {
      case .context: nil
      case .added: colors.addedBackground
      case .removed: colors.removedBackground
      }
    }

    private func drawGutter(for row: LineDiff.Row, in rowRect: CGRect) {
      let numberColor: UIColor
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
        (row.newLine ?? row.oldLine).map(String.init) ?? "",
        in: metrics.numberRect(rowRect),
        attributes: attributes
      )

      let marker: String
      let markerColor: UIColor
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
      (string as NSString).draw(
        at: CGPoint(
          x: rect.maxX - size.width,
          y: rect.minY + floor((rect.height - size.height) / 2)
        ),
        withAttributes: attributes
      )
    }

    private func drawCentered(
      _ string: String,
      in rect: CGRect,
      attributes: [NSAttributedString.Key: Any]
    ) {
      let size = (string as NSString).size(withAttributes: attributes)
      (string as NSString).draw(
        at: CGPoint(
          x: rect.minX + floor((rect.width - size.width) / 2),
          y: rect.minY + floor((rect.height - size.height) / 2)
        ),
        withAttributes: attributes
      )
    }

  }
#endif
