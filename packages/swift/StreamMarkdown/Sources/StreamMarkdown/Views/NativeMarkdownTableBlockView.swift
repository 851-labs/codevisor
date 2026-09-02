#if canImport(AppKit)
    import AppKit

    /// Settled-transcript table: the same TextKit table as `MarkdownTableView`,
    /// hosted directly (no SwiftUI) inside a `TableBleedContainer` so a table wider
    /// than its min-content width scrolls sideways instead of wrapping mid-word.
    @MainActor
    final class NativeMarkdownTableBlockView: NativeMarkdownContentView {
        private let tableView: TableTextView
        private let bleedContainer: TableBleedContainer
        private let model: TableModel
        private let renderMemo = MarkdownTableRenderMemo()
        private var measuredWidth: CGFloat = -1
        private var measuredHeight: CGFloat = 1

        init(
            headers: [MarkdownText],
            alignments: [ColumnAlignment],
            rows: [[MarkdownText]],
            theme: MarkdownTheme,
            linkAction: MarkdownLinkAction?
        ) {
            model = TableModel(
                headers: headers,
                alignments: alignments,
                rows: rows,
                theme: theme
            )

            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let container = NSTextContainer(
                size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
            )
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            tableView = TableTextView(frame: .zero, textContainer: container)
            bleedContainer = TableBleedContainer(tableTextView: tableView)

            super.init(frame: .zero)
            self.linkAction = linkAction
            tableView.linkAction = linkAction
            tableView.isEditable = false
            tableView.isSelectable = true
            tableView.drawsBackground = false
            tableView.textContainerInset = .zero
            tableView.isVerticallyResizable = true
            tableView.isHorizontallyResizable = false
            tableView.focusRingType = .none
            tableView.minSize = .zero
            tableView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            tableView.linkTextAttributes = [
                .foregroundColor: NSColor.linkColor,
                .cursor: NSCursor.pointingHand,
            ]
            tableView.update(model: model, renderMemo: renderMemo)
            bleedContainer.scrollView.setBorderColor(NSColor(theme.tableBorderColor))
            addSubview(bleedContainer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func linkActionDidChange() {
            tableView.linkAction = linkAction
        }

        override func contentHeight(forWidth proposedWidth: CGFloat) -> CGFloat {
            let width = max(1, proposedWidth)
            if abs(measuredWidth - width) <= 0.25 { return measuredHeight }
            measuredWidth = width
            // Lay out at the min-content width when the granted width is
            // narrower; the extra width scrolls inside `scrollView`.
            let layoutWidth = max(width, renderMemo.minimumWidth(for: model))
            measuredHeight = max(1, renderMemo.size(for: model, width: layoutWidth).height)
            return measuredHeight
        }

        override func layout() {
            super.layout()
            bleedContainer.frame = bounds
            bleedContainer.needsLayout = true
            bleedContainer.layoutSubtreeIfNeeded()
        }
    }
#endif
