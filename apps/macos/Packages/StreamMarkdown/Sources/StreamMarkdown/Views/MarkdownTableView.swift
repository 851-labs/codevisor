import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Renders a GFM table.
///
/// The table is drawn by an AppKit `NSTextView` backed by TextKit's
/// `NSTextTable`, rather than a SwiftUI `Grid` of separate `Text` views. On
/// macOS, `.textSelection` is scoped per `Text` and can never span two of
/// them, so a `Grid` can only ever offer per-cell selection. A single
/// `NSTextView` puts every cell in one text container, giving native
/// click-drag selection that spans any rows and columns, and ⌘C copies the
/// selection (as aligned tab/newline text — see `TableTextView`).
///
/// The table fills the width it is actually given (see `TableTextView.layout`),
/// so while a message streams in it only grows *downward* and never jitters
/// sideways. The rounded outer border comes from SwiftUI (TextKit block borders
/// are rectangular); TextKit draws the shaded header, the row hairlines, and
/// the cell text.
struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]

    @Environment(\.markdownTheme) private var theme

    var body: some View {
        SelectableTextTableView(headers: headers, alignments: alignments, rows: rows, theme: theme)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.tableBorderColor, lineWidth: 1)
            )
    }
}

/// The inputs needed to build a table, bundled so they compare cheaply for
/// change detection (the theme via its render fingerprint).
private struct TableModel: Equatable {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
    let theme: MarkdownTheme

    static func == (lhs: TableModel, rhs: TableModel) -> Bool {
        lhs.headers == rhs.headers && lhs.alignments == rhs.alignments && lhs.rows == rhs.rows
            && lhs.theme.renderFingerprint == rhs.theme.renderFingerprint
    }

    var contentHash: Int {
        var hasher = Hasher()
        hasher.combine(headers)
        hasher.combine(alignments.map(ordinal))
        hasher.combine(rows)
        hasher.combine(theme.renderFingerprint)
        return hasher.finalize()
    }

    private func ordinal(_ alignment: ColumnAlignment) -> Int {
        switch alignment {
        case .leading: return 0
        case .center: return 1
        case .trailing: return 2
        case .none: return 3
        }
    }
}

// MARK: - NSViewRepresentable

/// Hosts a non-editable, selectable `NSTextView` that renders a markdown table.
///
/// Sizing is split cleanly: the *display* is (re)built by the view's own
/// `layout()` at whatever width it is assigned, so it always fills its real
/// frame and is never disturbed by a measurement probe. `sizeThatFits` only
/// *measures* (on a scratch text stack) — importantly, its minimum-width probe
/// reports the table's true minimum, so the window stays freely resizable.
private struct SelectableTextTableView: NSViewRepresentable {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
    let theme: MarkdownTheme

    /// The floor a minimum-size probe reports, so a wide table never pins the
    /// window's minimum width to its own content width.
    private static let minimumWidth: CGFloat = 180

    private var model: TableModel {
        TableModel(headers: headers, alignments: alignments, rows: rows, theme: theme)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TableTextView {
        // Build an explicit TextKit 1 stack: `NSTextTable` is a TextKit 1
        // construct and does not lay out under an NSTextView's default
        // TextKit 2 stack.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = TableTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.focusRingType = .none
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.update(model: model)
        return textView
    }

    func updateNSView(_ textView: TableTextView, context: Context) {
        textView.update(model: model)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView textView: TableTextView, context: Context
    ) -> CGSize? {
        let coordinator = context.coordinator
        guard let proposed = proposal.width, proposed.isFinite else {
            // Unspecified / infinite proposal: the ideal size at the current
            // width (or a modest default before the view has one).
            let ideal = textView.bounds.width > 1 ? textView.bounds.width : 400
            return coordinator.size(for: model, width: ideal)
        }
        if proposed <= 1 {
            // Minimum-size probe. Reporting the current/full width here is what
            // previously pinned the window's minimum size and blocked resizing;
            // report the table's true minimum instead.
            return coordinator.size(for: model, width: Self.minimumWidth)
        }
        // A concrete width — fill it.
        return CGSize(width: proposed, height: coordinator.size(for: model, width: proposed).height)
    }

    /// Measures table sizes on a scratch TextKit 1 stack so probes never touch
    /// the displayed view. Memoized on (content, width).
    @MainActor
    final class Coordinator {
        private let storage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        private var key: Int?
        private var cached: CGSize?

        init() {
            storage.addLayoutManager(layoutManager)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
        }

        func size(for model: TableModel, width: CGFloat) -> CGSize {
            var hasher = Hasher()
            hasher.combine(model.contentHash)
            hasher.combine(width)
            let newKey = hasher.finalize()
            if newKey == key, let cached { return cached }

            let string = MarkdownTableRenderer.make(
                headers: model.headers, alignments: model.alignments, rows: model.rows,
                theme: model.theme, width: width
            )
            storage.setAttributedString(string)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let size = CGSize(width: ceil(used.width), height: ceil(used.height))
            key = newKey
            cached = size
            return size
        }
    }
}

// MARK: - NSTextView subclass

/// A read-only text view that renders a markdown table and copies selections as
/// tab-separated rows.
///
/// It (re)builds its table in `layout()` at its assigned width, so the table
/// always fills the frame SwiftUI grants — no chopped-off content, no sideways
/// jitter while streaming.
///
/// The copy override matters because copying spans of an `NSTextTable` otherwise
/// yields one cell per line (each cell is its own paragraph in the backing
/// store), losing the row/column shape when pasted as plain text. The rich (RTF)
/// representation from `super` is preserved for apps that accept it.
final class TableTextView: TranscriptSelectableTextView {
    private var model: TableModel?
    private var builtWidth: CGFloat = -1

    fileprivate func update(model: TableModel) {
        guard self.model != model else { return }
        self.model = model
        builtWidth = -1  // force a rebuild at the next layout pass
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width != builtWidth { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let model, bounds.width > 0, bounds.width != builtWidth else { return }
        let string = MarkdownTableRenderer.make(
            headers: model.headers, alignments: model.alignments, rows: model.rows,
            theme: model.theme, width: bounds.width
        )
        updateLinkHover(at: nil)
        textStorage?.setAttributedString(string)
        builtWidth = bounds.width
    }

    override func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        let handled = super.writeSelection(to: pboard, types: types)
        if types.contains(.string), let storage = textStorage,
            let tsv = Self.tsv(from: storage, in: selectedRange())
        {
            pboard.setString(tsv, forType: .string)
        }
        return handled
    }

    /// Rebuilds a range as TSV by grouping the cell paragraphs it covers (each
    /// tagged with an `NSTextTableBlock`) by row and column. Returns nil when
    /// the range contains no table cells, so non-table text (should there ever
    /// be any) falls back to the default copy behavior.
    static func tsv(from storage: NSAttributedString, in range: NSRange) -> String? {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }

        let nsString = storage.string as NSString
        var grid: [Int: [Int: String]] = [:]
        var sawCell = false
        let strip = CharacterSet(charactersIn: "\u{202F}").union(.newlines)

        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subRange, _ in
            guard let style = value as? NSParagraphStyle,
                let block = style.textBlocks.first as? NSTextTableBlock
            else { return }
            sawCell = true
            let text = nsString.substring(with: subRange).trimmingCharacters(in: strip)
            grid[block.startingRow, default: [:]][block.startingColumn, default: ""] += text
        }
        guard sawCell else { return nil }

        return grid.keys.sorted().map { rowIndex -> String in
            let columns = grid[rowIndex] ?? [:]
            guard let lowest = columns.keys.min(), let highest = columns.keys.max() else { return "" }
            return (lowest...highest).map { columns[$0] ?? "" }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

// MARK: - Attributed string construction

/// Builds the `NSAttributedString` for a markdown table as an `NSTextTable`:
/// each cell is a paragraph whose `NSParagraphStyle` carries a table block
/// pinning it to a (row, column). Inline markdown (emphasis, code, links)
/// inside cells is styled per-run.
enum MarkdownTableRenderer {
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 7

    /// - Parameter width: the width to fill (columns are scaled to it). Nil lays
    ///   the table out at its natural content width — used by tests.
    @MainActor
    static func make(
        headers: [String], alignments: [ColumnAlignment], rows: [[String]],
        theme: MarkdownTheme, width: CGFloat? = nil
    ) -> NSAttributedString {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let columnWidths = distribute(
            contentWidths: columnContentWidths(
                headers: headers, rows: rows, columnCount: columnCount, theme: theme
            ),
            toFit: width
        )

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.hidesEmptyCells = false

        // Header sits on a faint neutral fill (works in light and dark); rows
        // are separated by hairlines in the theme's border color. The last row
        // gets none — the SwiftUI rounded border closes off the bottom.
        let separatorColor = NSColor(theme.tableBorderColor)
        let headerBackground = NSColor.labelColor.withAlphaComponent(0.05)
        let lastRowIndex = rows.count

        let result = NSMutableAttributedString()
        appendRow(
            headers, rowIndex: 0, isHeader: true, columnCount: columnCount, alignments: alignments,
            columnWidths: columnWidths, table: table, separatorColor: separatorColor,
            headerBackground: headerBackground, lastRowIndex: lastRowIndex, theme: theme,
            into: result
        )
        for (offset, row) in rows.enumerated() {
            appendRow(
                row, rowIndex: offset + 1, isHeader: false, columnCount: columnCount,
                alignments: alignments, columnWidths: columnWidths, table: table,
                separatorColor: separatorColor, headerBackground: headerBackground,
                lastRowIndex: lastRowIndex, theme: theme, into: result
            )
        }
        return result
    }

    private static func appendRow(
        _ values: [String], rowIndex: Int, isHeader: Bool, columnCount: Int,
        alignments: [ColumnAlignment], columnWidths: [CGFloat], table: NSTextTable,
        separatorColor: NSColor, headerBackground: NSColor, lastRowIndex: Int,
        theme: MarkdownTheme, into result: NSMutableAttributedString
    ) {
        for column in 0..<columnCount {
            let value = column < values.count ? values[column] : ""
            let alignment = column < alignments.count ? alignments[column] : .none

            let block = NSTextTableBlock(
                table: table, startingRow: rowIndex, rowSpan: 1,
                startingColumn: column, columnSpan: 1
            )
            block.setValue(columnWidths[column], type: .absoluteValueType, for: .width)
            block.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(verticalPadding, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(verticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
            if isHeader {
                block.backgroundColor = headerBackground
            }
            // Hairline separator beneath every row except the last.
            if rowIndex < lastRowIndex {
                block.setBorderColor(separatorColor, for: .maxY)
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            paragraph.alignment = nsAlignment(alignment)

            let cell = NSMutableAttributedString(
                attributedString: inlineAttributed(value, isHeader: isHeader, theme: theme)
            )
            // Each table cell must be its own paragraph.
            cell.append(NSAttributedString(string: "\n"))
            cell.addAttribute(
                .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length)
            )
            result.append(cell)
        }
    }

    /// The natural (single-line) content width of each column: the widest cell,
    /// header included.
    private static func columnContentWidths(
        headers: [String], rows: [[String]], columnCount: Int, theme: MarkdownTheme
    ) -> [CGFloat] {
        var widths = [CGFloat](repeating: 1, count: columnCount)
        func consider(_ value: String, column: Int, isHeader: Bool) {
            guard column < columnCount else { return }
            let measured = inlineAttributed(value, isHeader: isHeader, theme: theme).size().width
            widths[column] = max(widths[column], ceil(measured))
        }
        for (column, header) in headers.enumerated() { consider(header, column: column, isHeader: true) }
        for row in rows {
            for (column, value) in row.enumerated() { consider(value, column: column, isHeader: false) }
        }
        return widths
    }

    /// Scales the natural column widths so the table fills `width` (columns keep
    /// their relative proportions, wrapping when squeezed). Nil width → natural
    /// widths unchanged.
    private static func distribute(contentWidths: [CGFloat], toFit width: CGFloat?) -> [CGFloat] {
        guard let width, width.isFinite, width > 0 else {
            return contentWidths.map { max(1, $0) }
        }
        let paddingTotal = horizontalPadding * 2 * CGFloat(contentWidths.count)
        let rawTotal = max(1, contentWidths.reduce(0, +))
        // Never let the content budget vanish: keep at least 1pt per column even
        // when the proposed width is smaller than the padding alone.
        let contentBudget = max(CGFloat(contentWidths.count), width - paddingTotal)
        let scale = contentBudget / rawTotal
        return contentWidths.map { max(1, $0 * scale) }
    }

    /// Styles one cell's inline markdown. Fonts resolve from the semantic text
    /// styles the theme uses by default (the host never overrides the markdown
    /// fonts); colors come from the theme.
    private static func inlineAttributed(
        _ markdown: String, isHeader: Bool, theme: MarkdownTheme
    ) -> NSAttributedString {
        let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        let baseFont = NSFont.systemFont(ofSize: bodySize, weight: isHeader ? .semibold : .regular)
        let codeFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
        )
        let codeBackground = NSColor(theme.inlineCodeBackground)

        let parsed = InlineMarkdown.attributedString(from: markdown)
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let substring = String(parsed[run.range].characters)
            guard !substring.isEmpty else { continue }
            let intent = run.inlinePresentationIntent

            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
            if intent?.contains(.code) == true {
                attributes[.font] = codeFont
                attributes[.backgroundColor] = codeBackground
            } else {
                attributes[.font] = styled(
                    baseFont,
                    bold: intent?.contains(.stronglyEmphasized) == true,
                    italic: intent?.contains(.emphasized) == true
                )
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            output.append(NSAttributedString(string: substring, attributes: attributes))
        }
        return output
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func nsAlignment(_ alignment: ColumnAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading, .none: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

#Preview {
    MarkdownTableView(
        headers: ["Name", "Age", "City"],
        alignments: [.leading, .center, .trailing],
        rows: [
            ["Ann", "30", "New York"],
            ["Bob", "25", "LA"],
            ["A very long name that wraps onto two lines", "1", "San Francisco"],
        ]
    )
    .padding()
    .frame(width: 420)
}
