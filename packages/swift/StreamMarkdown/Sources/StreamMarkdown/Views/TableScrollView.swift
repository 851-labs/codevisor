#if canImport(AppKit)
    import AppKit

    // MARK: - Bleed container

    /// The transcript-facing host for a table. Like the iOS renderer, the
    /// *bordered table* is what scrolls: the scroll viewport is widened past
    /// the text column on both sides (the "bleed", measured from the row's
    /// position inside the transcript) and the content is inset by the same
    /// amount, so a fitting table rests exactly on the text column and an
    /// overflowing one scrolls all the way to the transcript's edges.
    final class TableBleedContainer: NSView {
        let scrollView: TableScrollView
        private(set) var bleed: CGFloat = 0

        init(tableTextView: TableTextView) {
            scrollView = TableScrollView(tableTextView: tableTextView)
            super.init(frame: .zero)
            addSubview(scrollView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            bleed = measuredBleed()
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: bleed, bottom: 0, right: bleed)
            scrollView.frame = bounds.insetBy(dx: -bleed, dy: 0)
            scrollView.needsLayout = true
            scrollView.layoutSubtreeIfNeeded()
        }

        /// Events over the widened viewport still belong to the table even
        /// though it extends past this view's frame.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            let local = convert(point, from: superview)
            guard scrollView.frame.contains(local) else { return nil }
            return scrollView.hitTest(local)
        }

        /// The symmetric distance to the nearest edge of the enclosing
        /// transcript viewport — the transcript's own horizontal padding plus
        /// any centering slack — capped to keep the table inside it.
        private func measuredBleed() -> CGFloat {
            var ancestor = superview
            while let view = ancestor {
                if let transcript = view as? NSScrollView, transcript !== scrollView {
                    let clip = transcript.contentView
                    let rect = convert(bounds, to: clip)
                    let left = rect.minX - clip.bounds.minX
                    let right = clip.bounds.maxX - rect.maxX
                    return max(0, min(left, right).rounded(.down))
                }
                ancestor = view.superview
            }
            return 0
        }
    }

    // MARK: - Horizontal scroll host

    /// Scrolls the bordered table sideways when its min-content width exceeds
    /// the width the transcript grants. Vertical gestures are handed to the
    /// transcript (see `TranscriptHorizontalScrollView`), so a pointer resting
    /// on a table never freezes the conversation.
    final class TableScrollView: TranscriptHorizontalScrollView {
        let tableTextView: TableTextView
        private let document: TableDocumentView

        init(tableTextView: TableTextView) {
            self.tableTextView = tableTextView
            document = TableDocumentView(tableTextView: tableTextView)
            super.init(frame: .zero)
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = false
            hasHorizontalScroller = true
            scrollerStyle = .overlay
            autohidesScrollers = true
            horizontalScrollElasticity = .automatic
            verticalScrollElasticity = .none
            automaticallyAdjustsContentInsets = false
            documentView = document
        }

        func setBorderColor(_ color: NSColor) {
            document.setBorderColor(color)
        }

        override func layout() {
            super.layout()
            // The document rests on the text column (viewport minus the bleed
            // insets) or grows to the table's min-content width, whichever is
            // wider. The text view rebuilds its `NSTextTable` at that width.
            let columnWidth = contentView.bounds.width - contentInsets.left - contentInsets.right
            guard columnWidth > 0 else { return }
            let width = max(columnWidth, tableTextView.minimumTableWidth)
            if abs(tableTextView.frame.width - width) > 0.25 {
                tableTextView.setFrameSize(NSSize(width: width, height: tableTextView.frame.height))
            }
            tableTextView.layoutSubtreeIfNeeded()
            let height = max(contentView.bounds.height, tableTextView.frame.height)
            let size = NSSize(width: width, height: height)
            if document.frame.size != size {
                document.setFrameSize(size)
            }
            document.needsLayout = true
        }
    }

    // MARK: - Document

    /// The rounded, bordered table surface. It is the scroll document, so the
    /// border travels with the table when it scrolls — as on iOS.
    final class TableDocumentView: NSView {
        private let tableTextView: TableTextView

        init(tableTextView: TableTextView) {
            self.tableTextView = tableTextView
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = MarkdownTableMetrics.cornerRadius
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            addSubview(tableTextView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isFlipped: Bool { true }

        func setBorderColor(_ color: NSColor) {
            layer?.borderColor = color.cgColor
        }

        override func layout() {
            super.layout()
            let frame = NSRect(x: 0, y: 0, width: bounds.width, height: tableTextView.frame.height)
            if tableTextView.frame != frame { tableTextView.frame = frame }
        }
    }
#endif
