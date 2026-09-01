import AppKit
import CodevisorTheming
import CodevisorUI
import MarkdownCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

enum TranscriptMarkdownRowLayout {
    static let planHorizontalInset: CGFloat = 12
    static let planBottomInset: CGFloat = 12
}

struct TranscriptMarkdownRowStyle {
    var markdown: MarkdownTheme
    let planBackground: NSColor
    let planBorder: NSColor

    init(markdown: MarkdownTheme, appTheme: Theme) {
        self.markdown = markdown
        if let background = appTheme.palette?.cardBackground {
            planBackground = NSColor(
                srgbRed: CGFloat(background.r) / 255,
                green: CGFloat(background.g) / 255,
                blue: CGFloat(background.b) / 255,
                alpha: CGFloat(background.a)
            )
        } else {
            planBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.4)
        }
        planBorder = NSColor(appTheme.separator)
    }
}

/// Non-interactive structural chrome behind a native Markdown leaf.
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
    }

    private func drawPlanCard(
        chunk: TranscriptMarkdownChunk,
        style: TranscriptMarkdownRowStyle
    ) {
        style.planBackground.setFill()
        if chunk.isLastInDocument {
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            style.planBackground.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: min(8, bounds.height)).fill()
        } else {
            bounds.fill()
        }

        style.planBorder.setStroke()
        let border = NSBezierPath()
        border.lineWidth = 1
        border.move(to: NSPoint(x: 0.5, y: 0))
        if chunk.isLastInDocument {
            let bottom = bounds.height - 0.5
            border.line(to: NSPoint(x: 0.5, y: bottom - 7.5))
            border.curve(
                to: NSPoint(x: 8, y: bottom),
                controlPoint1: NSPoint(x: 0.5, y: bottom - 2.5),
                controlPoint2: NSPoint(x: 3, y: bottom)
            )
            border.line(to: NSPoint(x: bounds.width - 8, y: bottom))
            border.curve(
                to: NSPoint(x: bounds.width - 0.5, y: bottom - 7.5),
                controlPoint1: NSPoint(x: bounds.width - 3, y: bottom),
                controlPoint2: NSPoint(x: bounds.width - 0.5, y: bottom - 2.5)
            )
            border.line(to: NSPoint(x: bounds.width - 0.5, y: 0))
        } else {
            border.line(to: NSPoint(x: 0.5, y: bounds.height))
            border.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
            border.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        }
        border.stroke()
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
        NSColor(style.markdown.quoteBarColor).setFill()
        for depth in 0..<fragment.quoteDepth {
            NSRect(
                x: planInset + CGFloat(depth) * MarkdownFragmentMetrics.quoteIndent,
                y: 0,
                width: MarkdownFragmentMetrics.quoteBarWidth,
                height: max(1, bounds.height - planBottom)
            ).fill()
        }

        let markerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor(style.markdown.secondaryTextForeground),
        ]
        for marker in fragment.listMarkers {
            let x =
                planInset
                + CGFloat(fragment.quoteDepth) * MarkdownFragmentMetrics.quoteIndent
                + CGFloat(max(0, marker.depth - 1)) * MarkdownFragmentMetrics.listIndent
            NSAttributedString(string: marker.text, attributes: markerAttributes).draw(
                in: NSRect(
                    x: x,
                    y: 0,
                    width: MarkdownFragmentMetrics.listMarkerWidth,
                    height: bounds.height
                )
            )
        }
    }
}
