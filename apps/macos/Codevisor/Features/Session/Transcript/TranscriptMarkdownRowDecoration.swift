import AppKit
import CodevisorUI
import MarkdownCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

enum TranscriptMarkdownRowLayout {
  static let planHorizontalInset = PlanDocumentMetrics.horizontalPadding
  static let planBottomInset = PlanDocumentMetrics.bottomPadding
}

struct TranscriptMarkdownRowStyle {
  var markdown: MarkdownTheme
  let planBackground = NSColor.cardBackgroundColor
  let planBorder = NSColor.separatorColor
}

@MainActor
final class TranscriptMarkdownRowDecoration: NSView {
  private var chunk: TranscriptMarkdownChunk?
  private var style: TranscriptMarkdownRowStyle?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setContent(_ chunk: TranscriptMarkdownChunk, style: TranscriptMarkdownRowStyle) {
    self.chunk = chunk
    self.style = style
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let chunk, let style else { return }
    if chunk.container == .planDocument {
      drawPlanCard(chunk: chunk, style: style)
    }
    if let fragment = chunk.fragment {
      drawFragment(fragment, chunk: chunk, style: style)
    }
    if let marks = chunk.timeline {
      drawTimeline(marks)
    }
  }

  private func drawTimeline(_ marks: TranscriptTimelineMarks) {
    let x = TranscriptTimelineMarks.railX
    let dotY = TranscriptTimelineMarks.nodeCenterY
    let radius = TranscriptTimelineMarks.dotDiameter / 2
    let gap = radius + TranscriptTimelineMarks.nodeClearance
    let rail = NSBezierPath()
    rail.lineWidth = TranscriptTimelineMarks.railWidth
    if marks.railAbove {
      rail.move(to: NSPoint(x: x, y: 0))
      rail.line(to: NSPoint(x: x, y: marks.startsLine ? dotY - gap : bounds.height))
    }
    if marks.railBelow {
      rail.move(to: NSPoint(x: x, y: marks.startsLine ? dotY + gap : 0))
      rail.line(to: NSPoint(x: x, y: bounds.height))
    }
    NSColor.labelColor.withAlphaComponent(0.18).setStroke()
    rail.stroke()
    if marks.startsLine {
      NSColor.secondaryLabelColor.setFill()
      NSBezierPath(ovalIn: NSRect(x: x - radius, y: dotY - radius, width: radius * 2, height: radius * 2)).fill()
    }
  }

  private func drawPlanCard(
    chunk: TranscriptMarkdownChunk,
    style: TranscriptMarkdownRowStyle
  ) {
    style.planBackground.setFill()
    if chunk.isLastInDocument {
      let fill = cardEndOutline(inset: 0)
      fill.close()
      fill.fill()
    } else {
      bounds.fill()
    }

    style.planBorder.setStroke()
    let border: NSBezierPath
    if chunk.isLastInDocument {
      border = cardEndOutline(inset: 0.5)
    } else {
      border = NSBezierPath()
      border.move(to: NSPoint(x: 0.5, y: 0))
      border.line(to: NSPoint(x: 0.5, y: bounds.height))
      border.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
      border.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
    }
    border.lineWidth = 1
    border.stroke()
  }

  private func cardEndOutline(inset: CGFloat) -> NSBezierPath {
    let left = inset
    let right = bounds.width - inset
    let bottom = bounds.height - inset
    let path = NSBezierPath()
    path.move(to: NSPoint(x: left, y: 0))
    path.line(to: NSPoint(x: left, y: bounds.height - 8))
    path.curve(
      to: NSPoint(x: 8, y: bottom),
      controlPoint1: NSPoint(x: left, y: bottom - 2.5),
      controlPoint2: NSPoint(x: 3, y: bottom)
    )
    path.line(to: NSPoint(x: bounds.width - 8, y: bottom))
    path.curve(
      to: NSPoint(x: right, y: bounds.height - 8),
      controlPoint1: NSPoint(x: bounds.width - 3, y: bottom),
      controlPoint2: NSPoint(x: right, y: bottom - 2.5)
    )
    path.line(to: NSPoint(x: right, y: 0))
    return path
  }

  private func drawFragment(
    _ fragment: MarkdownFragmentLayout,
    chunk: TranscriptMarkdownChunk,
    style: TranscriptMarkdownRowStyle
  ) {
    let planInset =
      chunk.container == .planDocument
      ? TranscriptMarkdownRowLayout.planHorizontalInset
      : 0
    let planBottom =
      chunk.container == .planDocument && chunk.isLastInDocument
      ? TranscriptMarkdownRowLayout.planBottomInset
      : 0
    let top = chunk.topSpacing(in: style.markdown)
    if let context = NSGraphicsContext.current?.cgContext {
      let color = NSColor(style.markdown.quoteBarColor)
      for depth in 0..<fragment.quoteDepth {
        TextKitQuoteBarPainter.fill(
          NSRect(
            x: planInset + CGFloat(depth) * MarkdownFragmentMetrics.quoteIndent,
            y: top,
            width: MarkdownFragmentMetrics.quoteBarWidth,
            height: max(1, bounds.height - top - planBottom)
          ),
          color: color,
          in: context
        )
      }
    }

    let bodyFont = NSFont.preferredFont(forTextStyle: .body)
    for marker in fragment.listMarkers {
      let markerAttributes: [NSAttributedString.Key: Any] = [
        .font: MarkdownList.isBullet(marker.text) ? NSFont.boldSystemFont(ofSize: bodyFont.pointSize) : bodyFont,
        .foregroundColor: NSColor(style.markdown.secondaryTextForeground),
      ]
      let x =
        planInset
        + CGFloat(fragment.quoteDepth) * MarkdownFragmentMetrics.quoteIndent
        + CGFloat(max(0, marker.depth - 1)) * MarkdownFragmentMetrics.listIndent
        + MarkdownFragmentMetrics.listColumn(markers: [marker.text]).markerInset
      NSAttributedString(string: marker.text, attributes: markerAttributes).draw(
        in: NSRect(
          x: x,
          y: top,
          width: max(1, bounds.width - x),
          height: max(1, bounds.height - top)
        )
      )
    }
  }
}
