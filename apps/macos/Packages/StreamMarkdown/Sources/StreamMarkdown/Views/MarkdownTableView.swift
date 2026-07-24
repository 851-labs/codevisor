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
    /// Shares rendered widths between SwiftUI's measurement path and the
    /// displayed AppKit view. Without this memo, a table was independently
    /// constructed once by `sizeThatFits` and again by `TableTextView.layout`.
    @State private var renderMemo = MarkdownTableRenderMemo()

    var body: some View {
        SelectableTextTableView(
            model: TableModel(
                headers: headers,
                alignments: alignments,
                rows: rows,
                theme: theme
            ),
            renderMemo: renderMemo
        )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.tableBorderColor, lineWidth: 1)
            )
    }
}

/// The inputs needed to build a table. `contentKey` pre-hashes the potentially
/// large row matrix once when SwiftUI creates the view value; repeated TextKit
/// sizing probes then use an O(1) hash operation rather than walking every cell.
struct TableModel: Equatable {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
    let theme: MarkdownTheme
    let contentKey: MarkdownTableRenderCache.ContentKey

    init(
        headers: [String],
        alignments: [ColumnAlignment],
        rows: [[String]],
        theme: MarkdownTheme
    ) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
        self.theme = theme
        contentKey = MarkdownTableRenderCache.ContentKey(
            headers: headers,
            alignments: alignments,
            rows: rows,
            themeFingerprint: theme.renderFingerprint
        )
    }

    static func == (lhs: TableModel, rhs: TableModel) -> Bool {
        lhs.contentKey == rhs.contentKey
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
    let model: TableModel
    let renderMemo: MarkdownTableRenderMemo

    /// The floor a minimum-size probe reports, so a wide table never pins the
    /// window's minimum width to its own content width.
    private static let minimumWidth: CGFloat = 180

    func makeNSView(context _: Context) -> TableTextView {
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
        textView.update(model: model, renderMemo: renderMemo)
        return textView
    }

    func updateNSView(_ textView: TableTextView, context _: Context) {
        textView.update(model: model, renderMemo: renderMemo)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView textView: TableTextView, context _: Context
    ) -> CGSize? {
        guard let proposed = proposal.width, proposed.isFinite else {
            // Unspecified / infinite proposal: the ideal size at the current
            // width (or a modest default before the view has one).
            let ideal = textView.bounds.width > 1 ? textView.bounds.width : 400
            return renderMemo.size(for: model, width: ideal)
        }
        if proposed <= 1 {
            // Minimum-size probe. Reporting the current/full width here is what
            // previously pinned the window's minimum size and blocked resizing;
            // report the table's true minimum instead.
            return renderMemo.size(for: model, width: Self.minimumWidth)
        }
        // A concrete width — fill it.
        return CGSize(width: proposed, height: renderMemo.size(for: model, width: proposed).height)
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
    private var renderMemo: MarkdownTableRenderMemo?
    private var builtWidth: CGFloat = -1

    fileprivate func update(model: TableModel, renderMemo: MarkdownTableRenderMemo) {
        guard self.model != model || self.renderMemo !== renderMemo else { return }
        self.model = model
        self.renderMemo = renderMemo
        builtWidth = -1  // force a rebuild at the next layout pass
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - builtWidth) > 0.25 { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let model, let renderMemo, bounds.width > 0,
              abs(bounds.width - builtWidth) > 0.25 else { return }
        let string = renderMemo.attributedString(for: model, width: bounds.width)
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

// MARK: - Shared rendering and measurement

/// Per-mounted-table memo. It keeps the widths SwiftUI has already proposed
/// strongly reachable even if a very table-heavy transcript turns over the
/// bounded process cache between measurement and display.
@MainActor
final class MarkdownTableRenderMemo {
    private var contentKey: MarkdownTableRenderCache.ContentKey?
    private var entries: [CGFloat: MarkdownTableRenderCache.RenderedTable] = [:]
    private let cache: MarkdownTableRenderCache

    init(cache: MarkdownTableRenderCache = .shared) {
        self.cache = cache
    }

    func attributedString(for model: TableModel, width: CGFloat) -> NSAttributedString {
        entry(for: model, width: width).attributedString
    }

    func size(for model: TableModel, width: CGFloat) -> CGSize {
        let width = Self.normalized(width)
        let entry = entry(for: model, width: width)
        return cache.size(of: entry)
    }

    private func entry(
        for model: TableModel,
        width: CGFloat
    ) -> MarkdownTableRenderCache.RenderedTable {
        if let existingContentKey = contentKey,
           existingContentKey !== model.contentKey,
           existingContentKey != model.contentKey
        {
            contentKey = model.contentKey
            entries.removeAll(keepingCapacity: true)
        } else if contentKey == nil {
            contentKey = model.contentKey
        }
        let width = Self.normalized(width)
        if let cached = entries[width] { return cached }
        let cached = cache.renderedTable(for: model, width: width)
        entries[width] = cached
        return cached
    }

    private static func normalized(_ width: CGFloat) -> CGFloat {
        max(1, width)
    }
}

/// Bounded process cache for table preparation, rendered `NSTextTable`
/// strings, and TextKit measurements.
///
/// A table is normally touched by three independent paths: SwiftUI's sizing
/// probes, the displayed `NSTextView`, and a later remount while scrolling.
/// Sharing the immutable result here means those paths do not each parse every
/// cell and recreate every `NSTextTableBlock`. One scratch TextKit stack also
/// replaces the previous scratch stack retained by every mounted table.
@MainActor
final class MarkdownTableRenderCache {
    final class ContentKey: Hashable {
        let headers: [String]
        let alignments: [ColumnAlignment]
        let rows: [[String]]
        let themeFingerprint: Int
        private let digest: Int

        init(
            headers: [String],
            alignments: [ColumnAlignment],
            rows: [[String]],
            themeFingerprint: Int
        ) {
            self.headers = headers
            self.alignments = alignments
            self.rows = rows
            self.themeFingerprint = themeFingerprint

            var hasher = Hasher()
            hasher.combine(headers)
            for alignment in alignments {
                switch alignment {
                case .leading: hasher.combine(0)
                case .center: hasher.combine(1)
                case .trailing: hasher.combine(2)
                case .none: hasher.combine(3)
                }
            }
            hasher.combine(rows)
            hasher.combine(themeFingerprint)
            digest = hasher.finalize()
        }

        static func == (lhs: ContentKey, rhs: ContentKey) -> Bool {
            lhs === rhs
                || (
                    lhs.digest == rhs.digest
                        && lhs.themeFingerprint == rhs.themeFingerprint
                        && lhs.headers == rhs.headers
                        && lhs.alignments == rhs.alignments
                        && lhs.rows == rhs.rows
                )
        }

        func hash(into hasher: inout Hasher) {
            // The full matrix was hashed once in init. Equality still compares
            // the original values, so a digest collision can never reuse the
            // wrong rendered table.
            hasher.combine(digest)
        }
    }

    private struct RenderKey: Hashable {
        let content: ContentKey
        let width: CGFloat
    }

    private struct CellKey: Hashable {
        let markdown: String
        let isHeader: Bool
        let themeFingerprint: Int
    }

    private final class PreparedEntry {
        let table: MarkdownTableRenderer.PreparedTable
        var lastAccess: UInt64

        init(table: MarkdownTableRenderer.PreparedTable, lastAccess: UInt64) {
            self.table = table
            self.lastAccess = lastAccess
        }
    }

    final class RenderedTable {
        let attributedString: NSAttributedString
        fileprivate let width: CGFloat
        fileprivate var size: CGSize?
        fileprivate var lastAccess: UInt64

        fileprivate init(
            attributedString: NSAttributedString,
            width: CGFloat,
            lastAccess: UInt64
        ) {
            self.attributedString = attributedString
            self.width = width
            self.lastAccess = lastAccess
        }
    }

    private final class CellEntry {
        let cell: MarkdownTableRenderer.PreparedCell

        init(cell: MarkdownTableRenderer.PreparedCell) {
            self.cell = cell
        }
    }

    static let shared = MarkdownTableRenderCache()

    private let preparedLimit: Int
    private let renderLimit: Int
    private let cellLimit: Int
    private var preparedEntries: [ContentKey: PreparedEntry] = [:]
    private var renderEntries: [RenderKey: RenderedTable] = [:]
    private var cellEntries: [CellKey: CellEntry] = [:]
    /// Cell churn can be much higher than whole-table churn while streaming.
    /// Keep FIFO eviction O(1) amortized instead of scanning all 4K cells for
    /// the least-recently-used entry on every miss past the bound.
    private var cellInsertionOrder: [CellKey] = []
    private var cellInsertionHead = 0
    private var accessClock: UInt64 = 0

    /// A single reusable measurement stack for the whole process. Table
    /// measurement runs on the main actor, so it is never accessed concurrently.
    private let measurementStorage = NSTextStorage()
    private let measurementLayoutManager = NSLayoutManager()
    private let measurementContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

    /// Regression seams used by tests to verify that equivalent requests reuse
    /// work rather than silently rebuilding it.
    private(set) var preparationCount = 0
    private(set) var renderCount = 0
    private(set) var measurementCount = 0
    private(set) var cellPreparationCount = 0

    init(preparedLimit: Int = 128, renderLimit: Int = 128, cellLimit: Int = 4_096) {
        self.preparedLimit = max(1, preparedLimit)
        self.renderLimit = max(1, renderLimit)
        self.cellLimit = max(1, cellLimit)
        measurementStorage.addLayoutManager(measurementLayoutManager)
        measurementContainer.lineFragmentPadding = 0
        measurementLayoutManager.addTextContainer(measurementContainer)
    }

    func attributedString(for model: TableModel, width: CGFloat) -> NSAttributedString {
        renderedTable(for: model, width: width).attributedString
    }

    func size(for model: TableModel, width: CGFloat) -> CGSize {
        size(of: renderedTable(for: model, width: width))
    }

    func size(of entry: RenderedTable) -> CGSize {
        if let size = entry.size { return size }

        measurementStorage.setAttributedString(entry.attributedString)
        measurementContainer.containerSize = NSSize(
            width: entry.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        measurementLayoutManager.ensureLayout(for: measurementContainer)
        let used = measurementLayoutManager.usedRect(for: measurementContainer)
        let size = CGSize(width: ceil(used.width), height: ceil(used.height))
        entry.size = size
        measurementCount += 1
        return size
    }

    func renderedTable(for model: TableModel, width: CGFloat) -> RenderedTable {
        let width = max(1, width)
        let key = RenderKey(content: model.contentKey, width: width)
        if let cached = renderEntries[key] {
            touch(cached)
            return cached
        }

        let prepared = preparedTable(for: model)
        let attributed = MarkdownTableRenderer.make(
            prepared: prepared,
            alignments: model.alignments,
            theme: model.theme,
            width: width
        )
        renderCount += 1
        let entry = RenderedTable(
            attributedString: attributed,
            width: width,
            lastAccess: tick()
        )
        renderEntries[key] = entry
        evictOldestRenderEntryIfNeeded()
        return entry
    }

    private func preparedTable(for model: TableModel) -> MarkdownTableRenderer.PreparedTable {
        if let cached = preparedEntries[model.contentKey] {
            touch(cached)
            return cached.table
        }

        let prepared = MarkdownTableRenderer.prepare(
            headers: model.headers,
            rows: model.rows,
            theme: model.theme
        ) { [self, themeFingerprint = model.contentKey.themeFingerprint]
            markdown, isHeader, theme in
            preparedCell(
                markdown,
                isHeader: isHeader,
                theme: theme,
                themeFingerprint: themeFingerprint
            )
        }
        preparationCount += 1
        let entry = PreparedEntry(table: prepared, lastAccess: tick())
        preparedEntries[model.contentKey] = entry
        evictOldestPreparedEntryIfNeeded()
        return prepared
    }

    private func preparedCell(
        _ markdown: String,
        isHeader: Bool,
        theme: MarkdownTheme,
        themeFingerprint: Int
    ) -> MarkdownTableRenderer.PreparedCell {
        let key = CellKey(
            markdown: markdown,
            isHeader: isHeader,
            themeFingerprint: themeFingerprint
        )
        if let cached = cellEntries[key] {
            return cached.cell
        }

        let cell = MarkdownTableRenderer.prepareCell(
            markdown,
            isHeader: isHeader,
            theme: theme
        )
        cellPreparationCount += 1
        let entry = CellEntry(cell: cell)
        cellEntries[key] = entry
        cellInsertionOrder.append(key)
        evictOldestCellEntryIfNeeded()
        return cell
    }

    private func tick() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func touch(_ entry: PreparedEntry) {
        entry.lastAccess = tick()
    }

    private func touch(_ entry: RenderedTable) {
        entry.lastAccess = tick()
    }

    private func evictOldestPreparedEntryIfNeeded() {
        guard preparedEntries.count > preparedLimit,
              let oldest = preparedEntries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
        else { return }
        preparedEntries.removeValue(forKey: oldest.key)
    }

    private func evictOldestRenderEntryIfNeeded() {
        guard renderEntries.count > renderLimit,
              let oldest = renderEntries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
        else { return }
        renderEntries.removeValue(forKey: oldest.key)
    }

    private func evictOldestCellEntryIfNeeded() {
        while cellEntries.count > cellLimit,
              cellInsertionHead < cellInsertionOrder.count
        {
            let oldest = cellInsertionOrder[cellInsertionHead]
            cellInsertionHead += 1
            cellEntries.removeValue(forKey: oldest)
        }
        if cellInsertionHead > 1_024,
           cellInsertionHead * 2 > cellInsertionOrder.count
        {
            cellInsertionOrder.removeFirst(cellInsertionHead)
            cellInsertionHead = 0
        }
    }
}

// MARK: - Attributed string construction

/// Builds the `NSAttributedString` for a markdown table as an `NSTextTable`:
/// each cell is a paragraph whose `NSParagraphStyle` carries a table block
/// pinning it to a (row, column). Inline markdown (emphasis, code, links)
/// inside cells is styled per-run.
enum MarkdownTableRenderer {
    struct PreparedCell {
        let attributedString: NSAttributedString
        let naturalWidth: CGFloat
    }

    struct PreparedTable {
        let columnCount: Int
        let headers: [PreparedCell]
        let rows: [[PreparedCell]]
        let columnContentWidths: [CGFloat]
    }

    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 7

    /// - Parameter width: the width to fill (columns are scaled to it). Nil lays
    ///   the table out at its natural content width — used by tests.
    @MainActor
    static func make(
        headers: [String], alignments: [ColumnAlignment], rows: [[String]],
        theme: MarkdownTheme, width: CGFloat? = nil
    ) -> NSAttributedString {
        let prepared = prepare(headers: headers, rows: rows, theme: theme)
        return make(
            prepared: prepared,
            alignments: alignments,
            theme: theme,
            width: width
        )
    }

    /// Parses and styles every cell exactly once, retaining both its attributed
    /// representation and natural width. The previous renderer repeated this
    /// work during the width pass and again while constructing the table.
    @MainActor
    static func prepare(
        headers: [String],
        rows: [[String]],
        theme: MarkdownTheme
    ) -> PreparedTable {
        prepare(headers: headers, rows: rows, theme: theme) {
            markdown, isHeader, theme in
            prepareCell(markdown, isHeader: isHeader, theme: theme)
        }
    }

    @MainActor
    static func prepare(
        headers: [String],
        rows: [[String]],
        theme: MarkdownTheme,
        cellProvider: (_ markdown: String, _ isHeader: Bool, _ theme: MarkdownTheme) ->
            PreparedCell
    ) -> PreparedTable {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return PreparedTable(
                columnCount: 0,
                headers: [],
                rows: [],
                columnContentWidths: []
            )
        }

        var contentWidths = [CGFloat](repeating: 1, count: columnCount)
        func prepareRow(_ values: [String], isHeader: Bool) -> [PreparedCell] {
            (0..<columnCount).map { column in
                let markdown = column < values.count ? values[column] : ""
                let cell = cellProvider(markdown, isHeader, theme)
                contentWidths[column] = max(contentWidths[column], cell.naturalWidth)
                return cell
            }
        }

        let preparedHeaders = prepareRow(headers, isHeader: true)
        let preparedRows = rows.map { prepareRow($0, isHeader: false) }
        return PreparedTable(
            columnCount: columnCount,
            headers: preparedHeaders,
            rows: preparedRows,
            columnContentWidths: contentWidths
        )
    }

    @MainActor
    static func prepareCell(
        _ markdown: String,
        isHeader: Bool,
        theme: MarkdownTheme
    ) -> PreparedCell {
        let attributed = inlineAttributed(markdown, isHeader: isHeader, theme: theme)
        return PreparedCell(
            attributedString: attributed,
            naturalWidth: max(1, ceil(attributed.size().width))
        )
    }

    @MainActor
    static func make(
        prepared: PreparedTable,
        alignments: [ColumnAlignment],
        theme: MarkdownTheme,
        width: CGFloat? = nil
    ) -> NSAttributedString {
        guard prepared.columnCount > 0 else { return NSAttributedString() }
        let columnWidths = distribute(
            contentWidths: prepared.columnContentWidths,
            toFit: width
        )

        let table = NSTextTable()
        table.numberOfColumns = prepared.columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.hidesEmptyCells = false

        // Header sits on a faint neutral fill (works in light and dark); rows
        // are separated by hairlines in the theme's border color. The last row
        // gets none — the SwiftUI rounded border closes off the bottom.
        let separatorColor = NSColor(theme.tableBorderColor)
        let headerBackground = NSColor.labelColor.withAlphaComponent(0.05)
        let lastRowIndex = prepared.rows.count

        let result = NSMutableAttributedString()
        appendRow(
            prepared.headers,
            rowIndex: 0,
            isHeader: true,
            columnCount: prepared.columnCount,
            alignments: alignments,
            columnWidths: columnWidths,
            table: table,
            separatorColor: separatorColor,
            headerBackground: headerBackground,
            lastRowIndex: lastRowIndex,
            into: result
        )
        for (offset, row) in prepared.rows.enumerated() {
            appendRow(
                row,
                rowIndex: offset + 1,
                isHeader: false,
                columnCount: prepared.columnCount,
                alignments: alignments,
                columnWidths: columnWidths,
                table: table,
                separatorColor: separatorColor,
                headerBackground: headerBackground,
                lastRowIndex: lastRowIndex,
                into: result
            )
        }
        return result
    }

    private static func appendRow(
        _ cells: [PreparedCell], rowIndex: Int, isHeader: Bool, columnCount: Int,
        alignments: [ColumnAlignment], columnWidths: [CGFloat], table: NSTextTable,
        separatorColor: NSColor, headerBackground: NSColor, lastRowIndex: Int,
        into result: NSMutableAttributedString
    ) {
        for column in 0..<columnCount {
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
                attributedString: cells[column].attributedString
            )
            // Each table cell must be its own paragraph.
            cell.append(NSAttributedString(string: "\n"))
            cell.addAttribute(
                .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length)
            )
            result.append(cell)
        }
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
