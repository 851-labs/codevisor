#if canImport(AppKit)
    import AppKit
#endif
import CodeHighlighter
import CodevisorCore
import StreamMarkdown
import SwiftUI

/// Theme-independent diff structure prepared while a settled tool-call row is
/// still collapsed. Keeping this separate from `DiffRenderCache` lets the
/// first expanded frame render plain rows immediately; native highlighting can
/// then fill colors without changing geometry.
@MainActor
final class DiffStructureCache {
    struct Key: Hashable, Sendable {
        let oldText: String?
        let newText: String
    }

    struct Entry: Equatable, Sendable {
        let rows: [LineDiff.Row]
        let dedentedOld: String?
        let dedentedNew: String
    }

    static let shared = DiffStructureCache()

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<Entry, Never>] = [:]
    private let limit: Int

    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    func entry(for key: Key) -> Entry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    func prepare(_ key: Key) async -> Entry {
        if let entry = entry(for: key) { return entry }

        let task: Task<Entry, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) {
                let (dedentedOld, dedentedNew) = LineDiff.dedent(
                    old: key.oldText,
                    new: key.newText
                )
                return Entry(
                    rows: LineDiff.rows(old: dedentedOld, new: dedentedNew),
                    dedentedOld: dedentedOld,
                    dedentedNew: dedentedNew
                )
            }
            inFlight[key] = task
        }

        let entry = await task.value
        inFlight[key] = nil
        store(entry, for: key)
        return entry
    }

    private func store(_ entry: Entry, for key: Key) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[key] = entry
    }

    private func touch(_ key: Key) {
        guard order.last != key, let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}

/// Computed rows + highlights for recently rendered diffs. DiffView's
/// `@State` dies whenever its row is unmounted (session switches rebuild the
/// whole screen); without this process-level cache, every expanded diff
/// re-ran the Myers diff and re-highlighted on each revisit. Keyed by full
/// content (not hashes) so a collision can never render the wrong diff.
@MainActor
public final class DiffRenderCache {
    struct Key: Hashable {
        let path: String
        let oldText: String?
        let newText: String
        let themeKey: String
    }

    struct Entry {
        let rows: [LineDiff.Row]
        let dedentedOld: String?
        let dedentedNew: String
        let highlighted: [Int: AttributedString]
    }

    static let shared = DiffRenderCache()

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private let limit: Int

    /// Keys hold the full old/new texts, so the cap stays small.
    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    func entry(for key: Key) -> Entry? {
        guard let entry = entries[key] else { return nil }
        if order.last != key, let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return entry
    }

    func store(_ entry: Entry, for key: Key) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[key] = entry
    }
}

/// The portable horizontal scroll view needs the card width so narrow rows
/// still paint through its trailing edge. The macOS native surface receives
/// that width through `sizeThatFits`, avoiding a redundant geometry update.
private struct DiffViewportWidthReader: ViewModifier {
    @Binding var width: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(AppKit) || canImport(UIKit)
            content
        #else
            content.onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
        #endif
    }
}

/// A compact line-numbered diff for a tool-call file edit, computed by
/// `LineDiff` (real Myers line diff, git hunk ordering) with old/new gutters.
/// Shared indentation is stripped (edit snippets carry the source's full
/// nesting) and rows are syntax-highlighted asynchronously via the path's
/// language.
public struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String
    @Environment(\.theme) private var theme
    @Environment(\.codeHighlightTheme) private var highlightTheme
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    /// Rows are cached because streamed edits mutate `newText` repeatedly and
    /// the diff should be computed once per content change, not per body eval.
    @State private var cachedRows: [LineDiff.Row] = []
    @State private var cachedKey: Int = 0
    @State private var hasPreparedStructure = false
    @State private var dedentedOld: String?
    @State private var dedentedNew: String = ""
    /// Highlighted text per row id, swapped in when the native lexer catches up; rows
    /// render plain until then. Cleared on content change so stale colors
    /// never map onto shifted lines.
    @State private var highlightedRows: [Int: AttributedString] = [:]
    /// The scroll viewport width, so row backgrounds extend across the whole
    /// card even when every code line is narrower.
    @State private var viewportWidth: CGFloat = 0

    private var contentKey: Int {
        var hasher = Hasher()
        hasher.combine(oldText)
        hasher.combine(newText)
        return hasher.finalize()
    }

    public var body: some View {
        // Each diff has its own file header and per-file totals. Long lines
        // scroll horizontally; tall files use a bounded vertical viewport that
        // hands scrolling back to the transcript at either edge.
        // The body paints the theme's editor background — the surface the
        // token colors were designed for (pierre's --diffs-bg).
        // Freshly recycled rows (empty @State) render straight from the
        // shared cache on their first frame; `.task` then re-seeds the local
        // state without recomputing.
        let localStructureIsCurrent = hasPreparedStructure && cachedKey == contentKey
        let cached = localStructureIsCurrent ? nil : DiffRenderCache.shared.entry(for: renderKey)
        let structure =
            !localStructureIsCurrent && cached == nil
            ? DiffStructureCache.shared.entry(for: structureKey)
            : nil
        let structureIsReady = localStructureIsCurrent || cached != nil || structure != nil
        let rows = cached?.rows ?? structure?.rows ?? (localStructureIsCurrent ? cachedRows : [])
        let highlights = cached?.highlighted ?? (localStructureIsCurrent ? highlightedRows : [:])
        VStack(alignment: .leading, spacing: 0) {
            diffHeader(totals: structureIsReady ? totals(for: rows) : nil)

            Divider()

            Group {
                if structureIsReady {
                    diffBody(rows, highlights: highlights)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing diff…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .modifier(DiffViewportWidthReader(width: $viewportWidth))
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Match fenced Markdown code blocks' single, rounded content surface;
        // the stroke keeps the file boundary legible against every theme.
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: 1)
        }
        // `clipShape` clips drawing but not hit testing. Constrain the native
        // selectable rows as well so no invisible text surface can overlap the
        // disclosure title above the card.
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .task(id: highlightKey) { await refreshRowsAndHighlight() }
    }

    private func diffHeader(totals: LineDiff.Totals?) -> some View {
        HStack(spacing: 8) {
            Text(fileName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 8)
            if let totals {
                DiffCounter(totals: totals)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func diffBody(
        _ rows: [LineDiff.Row],
        highlights: [Int: AttributedString]
    ) -> some View {
        #if canImport(AppKit)
            // One TextKit document per file: gutters and row fills are drawn
            // by the native surface instead of mounting a text view per line.
            NativeDiffView(
                rows: rows,
                highlights: highlights,
                theme: theme,
                revision: "\(highlightKey)|\(highlights.count)"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        #elseif canImport(UIKit)
            IOSNativeDiffView(
                rows: rows,
                highlights: highlights,
                theme: theme,
                revision: "\(highlightKey)|\(highlights.count)"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
            ScrollView(.horizontal, showsIndicators: true) {
                diffRows(rows, highlights: highlights)
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        #endif
    }

    private func diffRows(
        _ rows: [LineDiff.Row],
        highlights: [Int: AttributedString]
    ) -> some View {
        let gutterWidth = gutterWidth(for: rows)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                rowView(row, gutterWidth: gutterWidth, highlights: highlights)
            }
        }
        // Row backgrounds run to at least the viewport edge; wider code still
        // scrolls horizontally.
        .frame(minWidth: viewportWidth, alignment: .leading)
    }

    private var fileName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func totals(for rows: [LineDiff.Row]) -> LineDiff.Totals {
        rows.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { result, row in
            switch row.kind {
            case .context: break
            case .added: result.added += 1
            case .removed: result.removed += 1
            }
        }
    }

    private var codeFont: OSFont {
        OSFont.monospacedSystemFont(
            ofSize: OSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
    }

    /// Gutters sized to the widest line number instead of a fixed column —
    /// a 6-line diff shouldn't reserve space for five-digit files.
    private func gutterWidth(for rows: [LineDiff.Row]) -> CGFloat {
        let maxLine = rows.reduce(1) { partial, row in
            max(partial, row.oldLine ?? 0, row.newLine ?? 0)
        }
        return CGFloat(max(2, String(maxLine).count)) * 7
    }

    private func rowView(
        _ row: LineDiff.Row,
        gutterWidth: CGFloat,
        highlights: [Int: AttributedString]
    ) -> some View {
        HStack(spacing: 6) {
            Text(row.oldLine.map(String.init) ?? "")
                .frame(width: gutterWidth, alignment: .trailing)
                .foregroundStyle(lineNumberColor(for: row.kind))
            Text(row.newLine.map(String.init) ?? "")
                .frame(width: gutterWidth, alignment: .trailing)
                .foregroundStyle(lineNumberColor(for: row.kind))
            Text(marker(for: row.kind))
                .frame(width: 8)
                .foregroundStyle(tint(for: row.kind))
            // Removed lines keep full syntax colors (pierre does not dim or
            // strike them); the row tint alone marks the deletion.
            #if canImport(AppKit) || canImport(UIKit)
                SelectableTextView(
                    attributedText: rowText(row, highlights: highlights),
                    fillsWidth: false
                )
            #else
                Text(portableRowText(row, highlights: highlights))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(nil)
            #endif
            Spacer(minLength: 0)
        }
        .font(.caption.monospaced())
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(background(for: row.kind))
    }

    /// Context numbers use the muted gutter tone; changed lines take the
    /// addition/deletion base color, matching pierre's gutter behavior.
    private func lineNumberColor(for kind: LineDiff.Row.Kind) -> Color {
        switch kind {
        case .context: theme.diffLineNumberFg
        case .added: theme.diffAddedFg
        case .removed: theme.diffRemovedFg
        }
    }

    #if !canImport(AppKit) && !canImport(UIKit)
        /// AttributedString flavor of `rowText` for the SwiftUI fallback path.
        private func portableRowText(
            _ row: LineDiff.Row,
            highlights: [Int: AttributedString]
        ) -> AttributedString {
            guard let highlighted = highlights[row.id], !row.text.isEmpty else {
                var plain = AttributedString(row.text.isEmpty ? " " : row.text)
                plain.foregroundColor = theme.textPrimary
                return plain
            }
            var result = AttributedString()
            for run in highlighted.runs {
                var piece = AttributedString(highlighted[run.range])
                if piece.foregroundColor == nil {
                    piece.foregroundColor = theme.textPrimary
                }
                result += piece
            }
            return result
        }
    #endif

    #if canImport(AppKit) || canImport(UIKit)
        /// Row text: syntax-highlighted when the path's language and the theme
        /// allow it, plain otherwise. Blank lines render a space to keep height.
        private func rowText(
            _ row: LineDiff.Row,
            highlights: [Int: AttributedString]
        ) -> NSAttributedString {
            let font = codeFont
            guard let highlighted = highlights[row.id], !row.text.isEmpty else {
                return NSAttributedString(
                    string: row.text.isEmpty ? " " : row.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: OSColor(theme.textPrimary),
                    ]
                )
            }
            let result = NSMutableAttributedString()
            for run in highlighted.runs {
                result.append(
                    NSAttributedString(
                        string: String(highlighted[run.range].characters),
                        attributes: [
                            .font: font,
                            .foregroundColor: run.foregroundColor.map { OSColor($0) }
                                ?? OSColor(theme.textPrimary),
                        ]
                    )
                )
            }
            return result
        }
    #endif

    /// Recomputes the diff rows (when the content changed) and re-highlights.
    /// The Myers diff runs off the main actor: streamed edits rewrite
    /// `newText` repeatedly, and diffing whole file contents on main per
    /// rewrite was a visible stall on large edits. `task(id:)` cancellation
    /// makes the sleep a trailing-edge debounce; the first computation (a
    /// finished diff scrolled back into view) skips it and renders promptly.
    private func refreshRowsAndHighlight() async {
        let key = contentKey
        if key != cachedKey || cachedRows.isEmpty {
            // A diff scrolled back into view: re-seed local state from the
            // shared cache instead of recomputing rows and highlights.
            if let entry = DiffRenderCache.shared.entry(for: renderKey) {
                cachedKey = key
                hasPreparedStructure = true
                dedentedOld = entry.dedentedOld
                dedentedNew = entry.dedentedNew
                cachedRows = entry.rows
                highlightedRows = entry.highlighted
                return
            }
            let computed: DiffStructureCache.Entry
            if let prepared = DiffStructureCache.shared.entry(for: structureKey) {
                computed = prepared
            } else {
                if !cachedRows.isEmpty {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                computed = await DiffStructureCache.shared.prepare(structureKey)
            }
            guard !Task.isCancelled else { return }
            cachedKey = key
            hasPreparedStructure = true
            dedentedOld = computed.dedentedOld
            dedentedNew = computed.dedentedNew
            cachedRows = computed.rows
            highlightedRows = [:]
            // A cache miss replaces the bounded loading row with the final
            // native diff height in one transcript measurement commit.
            invalidateRowMeasurement?()
        }
        await highlightRows()
        guard !Task.isCancelled else { return }
        DiffRenderCache.shared.store(
            DiffRenderCache.Entry(
                rows: cachedRows,
                dedentedOld: dedentedOld,
                dedentedNew: dedentedNew,
                highlighted: highlightedRows
            ),
            for: renderKey
        )
    }

    private var renderKey: DiffRenderCache.Key {
        DiffRenderCache.Key(
            path: path,
            oldText: oldText,
            newText: newText,
            themeKey: highlightTheme?.key ?? ""
        )
    }

    private var structureKey: DiffStructureCache.Key {
        DiffStructureCache.Key(oldText: oldText, newText: newText)
    }

    private var highlightKey: String {
        "\(highlightTheme?.key ?? "")|\(path)|\(contentKey)"
    }

    private func highlightRows() async {
        guard
            let highlightTheme,
            let language = CodeHighlighter.language(forPath: path)
        else {
            highlightedRows = [:]
            return
        }
        let rows = cachedRows

        let newTokens = await CodeHighlighter.shared.highlight(
            code: dedentedNew, language: language,
            themeKey: highlightTheme.key, themeJSON: highlightTheme.json
        )
        var oldTokens: [[CodeHighlighter.Token]]?
        if let dedentedOld, rows.contains(where: { $0.kind == .removed }) {
            oldTokens = await CodeHighlighter.shared.highlight(
                code: dedentedOld, language: language,
                themeKey: highlightTheme.key, themeJSON: highlightTheme.json
            )
        }
        guard !Task.isCancelled else { return }

        // Added/context rows read from the new text's token lines, removed
        // rows from the old text's — both 1-based like LineDiff.Row.
        var result: [Int: AttributedString] = [:]
        for row in rows {
            let line: [CodeHighlighter.Token]?
            if let newLine = row.newLine {
                line = newTokens.flatMap { $0.indices.contains(newLine - 1) ? $0[newLine - 1] : nil }
            } else if let oldLine = row.oldLine {
                line = oldTokens.flatMap { $0.indices.contains(oldLine - 1) ? $0[oldLine - 1] : nil }
            } else {
                line = nil
            }
            if let line, !line.isEmpty {
                result[row.id] = attributedLine(line)
            }
        }
        highlightedRows = result
    }

    private func marker(for kind: LineDiff.Row.Kind) -> String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private func tint(for kind: LineDiff.Row.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: theme.diffAddedFg
        case .removed: theme.diffRemovedFg
        }
    }

    private func background(for kind: LineDiff.Row.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added: theme.diffAddedBg
        case .removed: theme.diffRemovedBg
        }
    }
}

#Preview {
    DiffView(
        path: "Features/Session/BranchDiffBadge.swift",
        oldText: """
                        var body: some View {
                            HStack(spacing: 0) {
                                if let totals {
                                    DiffCounter(totals: totals)
                                }
                            }
                        }
            """,
        newText: """
                        var body: some View {
                            HStack(spacing: 0) {
                                // Show the counter only once there is a real diff.
                                if let totals, totals.added > 0 || totals.removed > 0 {
                                    DiffCounter(totals: totals)
                                }
                            }
                        }
            """
    )
    .padding()
    .frame(width: 520)
}
