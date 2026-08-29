#if canImport(AppKit)
    import AppKit
    import StreamMarkdown
    import SwiftUI
    import TranscriptKit

    /// A complete file diff rendered by one TextKit surface. Diff rows remain
    /// ordinary text in a single storage object; the view draws gutters and row
    /// fills itself, so line count does not multiply the AppKit/SwiftUI view tree.
    struct NativeDiffView: NSViewRepresentable {
        let rows: [LineDiff.Row]
        let highlights: [Int: AttributedString]
        let theme: Theme
        let revision: String

        func makeNSView(context: Context) -> NativeDiffScrollView {
            let scrollView = NativeDiffScrollView()
            scrollView.setContent(
                rows: rows,
                highlights: highlights,
                theme: theme,
                revision: revision
            )
            return scrollView
        }

        func updateNSView(_ scrollView: NativeDiffScrollView, context: Context) {
            scrollView.setContent(
                rows: rows,
                highlights: highlights,
                theme: theme,
                revision: revision
            )
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView scrollView: NativeDiffScrollView,
            context: Context
        ) -> CGSize? {
            let width =
                proposal.width.flatMap { $0.isFinite ? $0 : nil }
                ?? scrollView.contentFittingSize.width
            return scrollView.fitContent(toViewportWidth: max(1, width))
        }
    }

    @MainActor
    final class NativeDiffScrollView: TranscriptHorizontalScrollView {
        private(set) var diffTextView: NativeDiffTextView
        private(set) var contentFittingSize = CGSize(width: 1, height: 1)
        private var renderedRevision: String?
        private var renderedTheme: Theme?

        override init(frame frameRect: NSRect) {
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer(
                size: NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            textContainer.lineFragmentPadding = 0
            textContainer.widthTracksTextView = false
            textContainer.heightTracksTextView = false
            layoutManager.addTextContainer(textContainer)
            diffTextView = NativeDiffTextView(frame: .zero, textContainer: textContainer)

            super.init(frame: frameRect)
            drawsBackground = false
            borderType = .noBorder
            hasHorizontalScroller = false
            hasVerticalScroller = false
            autohidesScrollers = true
            scrollerStyle = .overlay
            horizontalScrollElasticity = .automatic
            automaticallyAdjustsContentInsets = false

            diffTextView.isEditable = false
            diffTextView.isSelectable = true
            diffTextView.isRichText = true
            diffTextView.drawsBackground = false
            diffTextView.isHorizontallyResizable = true
            diffTextView.isVerticallyResizable = true
            diffTextView.minSize = .zero
            diffTextView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            diffTextView.focusRingType = .none
            diffTextView.allowsUndo = false
            diffTextView.isContinuousSpellCheckingEnabled = false
            diffTextView.isGrammarCheckingEnabled = false
            diffTextView.isAutomaticSpellingCorrectionEnabled = false
            diffTextView.isAutomaticTextReplacementEnabled = false
            diffTextView.isAutomaticQuoteSubstitutionEnabled = false
            diffTextView.isAutomaticDashSubstitutionEnabled = false
            diffTextView.isAutomaticLinkDetectionEnabled = false
            documentView = diffTextView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setContent(
            rows: [LineDiff.Row],
            highlights: [Int: AttributedString],
            theme: Theme,
            revision: String
        ) {
            guard renderedRevision != revision || renderedTheme != theme else { return }
            renderedRevision = revision
            renderedTheme = theme

            let metrics = NativeDiffMetrics(rows: rows)
            let text = Self.attributedText(
                rows: rows,
                highlights: highlights,
                font: metrics.font,
                rowHeight: metrics.rowHeight,
                foreground: NSColor(theme.textPrimary)
            )
            diffTextView.setContent(
                text,
                rows: rows,
                metrics: metrics,
                colors: NativeDiffColors(theme: theme)
            )

            guard let layoutManager = diffTextView.layoutManager,
                let textContainer = diffTextView.textContainer
            else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let contentWidth = max(
                1,
                ceil(metrics.textInset + used.maxX + metrics.trailingPadding)
            )
            // The paragraph style pins every row to the same native line box.
            // Counting those boxes also covers an empty final row, for which
            // TextKit has no glyph range to include in `usedRect`.
            let textHeight = max(ceil(used.maxY), CGFloat(rows.count) * metrics.rowHeight)
            contentFittingSize = CGSize(
                width: contentWidth,
                height: max(1, ceil(metrics.verticalPadding * 2 + textHeight))
            )
            fitDocument(
                toViewportSize: CGSize(
                    width: max(bounds.width, 1),
                    height: visibleContentHeight
                )
            )
            invalidateIntrinsicContentSize()
        }

        @discardableResult
        func fitContent(toViewportWidth viewportWidth: CGFloat) -> CGSize {
            let viewportSize = CGSize(width: viewportWidth, height: visibleContentHeight)
            fitDocument(toViewportSize: viewportSize)
            return viewportSize
        }

        override func layout() {
            super.layout()
            guard bounds.width > 0 else { return }
            fitDocument(
                toViewportSize: CGSize(
                    width: bounds.width,
                    height: bounds.height > 0 ? min(bounds.height, visibleContentHeight) : visibleContentHeight
                )
            )
        }

        override func shouldConsumeVerticalScroll(_ event: NSEvent) -> Bool {
            canConsumeVerticalDelta(event.scrollingDeltaY)
        }

        func canConsumeVerticalDelta(_ deltaY: CGFloat) -> Bool {
            guard hasVerticalScroller, deltaY != 0 else { return false }

            let visibleRect = contentView.documentVisibleRect
            let documentRect = diffTextView.bounds
            let boundaryTolerance: CGFloat = 0.5
            if deltaY > 0 {
                return visibleRect.minY > documentRect.minY + boundaryTolerance
            }
            return visibleRect.maxY < documentRect.maxY - boundaryTolerance
        }

        private var visibleContentHeight: CGFloat {
            min(contentFittingSize.height, DiffViewportMetrics.maximumHeight)
        }

        private func fitDocument(toViewportSize viewportSize: CGSize) {
            let documentSize = CGSize(
                width: max(viewportSize.width, contentFittingSize.width),
                height: contentFittingSize.height
            )
            if diffTextView.frame.size != documentSize {
                diffTextView.setFrameSize(documentSize)
            }
            let shouldScrollHorizontally = contentFittingSize.width > viewportSize.width + 0.5
            if hasHorizontalScroller != shouldScrollHorizontally {
                hasHorizontalScroller = shouldScrollHorizontally
            }
            let shouldScrollVertically = contentFittingSize.height > viewportSize.height + 0.5
            if hasVerticalScroller != shouldScrollVertically {
                hasVerticalScroller = shouldScrollVertically
            }
            reflectScrolledClipView(contentView)
        }

        private static func attributedText(
            rows: [LineDiff.Row],
            highlights: [Int: AttributedString],
            font: NSFont,
            rowHeight: CGFloat,
            foreground: NSColor
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = rowHeight
            paragraph.maximumLineHeight = rowHeight

            for (index, row) in rows.enumerated() {
                if let highlighted = highlights[row.id], !row.text.isEmpty {
                    for run in highlighted.runs {
                        result.append(
                            NSAttributedString(
                                string: String(highlighted[run.range].characters),
                                attributes: [
                                    .font: font,
                                    .foregroundColor: run.foregroundColor.map(NSColor.init)
                                        ?? foreground,
                                    .paragraphStyle: paragraph,
                                ]
                            )
                        )
                    }
                } else if !row.text.isEmpty {
                    result.append(
                        NSAttributedString(
                            string: row.text,
                            attributes: [
                                .font: font,
                                .foregroundColor: foreground,
                                .paragraphStyle: paragraph,
                            ]
                        )
                    )
                }
                if index < rows.count - 1 {
                    result.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: [
                                .font: font,
                                .foregroundColor: foreground,
                                .paragraphStyle: paragraph,
                            ]
                        )
                    )
                }
            }
            return result
        }
    }

    @MainActor
    final class NativeDiffTextView: TranscriptSelectableTextView {
        private var rows: [LineDiff.Row] = []
        private var metrics = NativeDiffMetrics(rows: [])
        private var colors = NativeDiffColors(theme: .system)

        func setContent(
            _ text: NSAttributedString,
            rows: [LineDiff.Row],
            metrics: NativeDiffMetrics,
            colors: NativeDiffColors
        ) {
            let selection = selectedRange()
            textStorage?.beginEditing()
            textStorage?.setAttributedString(text)
            textStorage?.endEditing()
            self.rows = rows
            self.metrics = metrics
            self.colors = colors
            textContainerInset = NSSize(width: metrics.textInset, height: metrics.verticalPadding)
            let safeSelection = NSRange(
                location: min(selection.location, text.length),
                length: min(selection.length, max(0, text.length - min(selection.location, text.length)))
            )
            setSelectedRange(safeSelection)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            drawDecorations(in: dirtyRect)
            super.draw(dirtyRect)
        }

        func rowRect(at index: Int) -> CGRect? {
            guard rows.indices.contains(index) else { return nil }
            return CGRect(
                x: 0,
                y: metrics.verticalPadding + CGFloat(index) * metrics.rowHeight,
                width: bounds.width,
                height: metrics.rowHeight
            )
        }

        private func drawDecorations(in dirtyRect: CGRect) {
            guard !rows.isEmpty else { return }
            let contentMinY = max(0, dirtyRect.minY - metrics.verticalPadding)
            let contentMaxY = max(0, dirtyRect.maxY - metrics.verticalPadding)
            let first = max(0, Int(floor(contentMinY / metrics.rowHeight)))
            let last = min(rows.count - 1, Int(floor(contentMaxY / metrics.rowHeight)))
            guard first <= last else { return }

            for index in first...last {
                guard let rowRect = rowRect(at: index) else { continue }
                let row = rows[index]
                backgroundColor(for: row.kind).setFill()
                rowRect.fill()
                drawGutter(for: row, in: rowRect)
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

        private func backgroundColor(for kind: LineDiff.Row.Kind) -> NSColor {
            switch kind {
            case .context: .clear
            case .added: colors.addedBackground
            case .removed: colors.removedBackground
            }
        }
    }

    struct NativeDiffMetrics {
        let font: NSFont
        let rowHeight: CGFloat
        let verticalPadding: CGFloat = 0
        let horizontalPadding: CGFloat = 8
        let gutterSpacing: CGFloat = 6
        let markerWidth: CGFloat = 8
        let trailingPadding: CGFloat = 8
        let gutterWidth: CGFloat

        init(rows: [LineDiff.Row]) {
            font = NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .regular
            )
            rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 2
            let maxLine = rows.reduce(1) { partial, row in
                max(partial, row.oldLine ?? 0, row.newLine ?? 0)
            }
            let digits = max(2, String(maxLine).count)
            let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
            gutterWidth = CGFloat(digits) * digitWidth
        }

        var textInset: CGFloat {
            horizontalPadding + gutterWidth + gutterSpacing + gutterWidth
                + gutterSpacing + markerWidth + gutterSpacing
        }

        func oldNumberRect(_ rowRect: CGRect) -> CGRect {
            CGRect(
                x: horizontalPadding,
                y: rowRect.minY,
                width: gutterWidth,
                height: rowRect.height
            )
        }

        func newNumberRect(_ rowRect: CGRect) -> CGRect {
            CGRect(
                x: horizontalPadding + gutterWidth + gutterSpacing,
                y: rowRect.minY,
                width: gutterWidth,
                height: rowRect.height
            )
        }

        func markerRect(_ rowRect: CGRect) -> CGRect {
            CGRect(
                x: horizontalPadding + gutterWidth + gutterSpacing + gutterWidth + gutterSpacing,
                y: rowRect.minY,
                width: markerWidth,
                height: rowRect.height
            )
        }
    }

    struct NativeDiffColors {
        let lineNumber: NSColor
        let addedForeground: NSColor
        let removedForeground: NSColor
        let addedBackground: NSColor
        let removedBackground: NSColor

        init(theme: Theme) {
            lineNumber = NSColor(theme.diffLineNumberFg)
            addedForeground = NSColor(theme.diffAddedFg)
            removedForeground = NSColor(theme.diffRemovedFg)
            addedBackground = NSColor(theme.diffAddedBg)
            removedBackground = NSColor(theme.diffRemovedBg)
        }
    }
#endif
