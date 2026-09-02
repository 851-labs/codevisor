#if canImport(AppKit)
    import AppKit

    // MARK: - Horizontal scroll host

    /// Hosts `TableTextView` and scrolls it sideways when the table's min-content
    /// width exceeds the width the transcript grants. Vertical gestures are
    /// handed to the transcript (see `TranscriptHorizontalScrollView`), so a
    /// pointer resting on a table never freezes the conversation.
    final class TableScrollView: TranscriptHorizontalScrollView {
        let tableTextView: TableTextView

        init(tableTextView: TableTextView) {
            self.tableTextView = tableTextView
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
            documentView = tableTextView
        }

        override func layout() {
            super.layout()
            // The document is as wide as the viewport, or as wide as the
            // table's min-content width when that is larger. The text view
            // rebuilds its `NSTextTable` at whatever width it is given.
            let viewportWidth = contentView.bounds.width
            guard viewportWidth > 0 else { return }
            let width = max(viewportWidth, tableTextView.minimumTableWidth)
            if abs(tableTextView.frame.width - width) > 0.25 {
                tableTextView.setFrameSize(NSSize(width: width, height: tableTextView.frame.height))
            }
            tableTextView.layoutSubtreeIfNeeded()
            let height = max(contentView.bounds.height, tableTextView.frame.height)
            if abs(tableTextView.frame.height - height) > 0.25 {
                tableTextView.setFrameSize(NSSize(width: width, height: height))
            }
        }
    }
#endif
