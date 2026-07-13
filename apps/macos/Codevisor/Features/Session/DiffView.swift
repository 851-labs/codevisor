import CodeHighlighter
import CodevisorCore
import SwiftUI

/// Computed rows + highlights for recently rendered diffs. DiffView's
/// `@State` dies whenever its row is unmounted (session switches rebuild the
/// whole screen); without this process-level cache, every expanded diff
/// re-ran the Myers diff and re-highlighted on each revisit. Keyed by full
/// content (not hashes) so a collision can never render the wrong diff.
@MainActor
final class DiffRenderCache {
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

/// A compact line-numbered diff for a tool-call file edit, computed by
/// `LineDiff` (real Myers line diff, git hunk ordering) with old/new gutters.
/// Shared indentation is stripped (edit snippets carry the source's full
/// nesting) and rows are Shiki-highlighted asynchronously via the path's
/// language.
struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String
    @Environment(\.theme) private var theme
    @Environment(\.codeHighlightTheme) private var highlightTheme

    /// Rows are cached because streamed edits mutate `newText` repeatedly and
    /// the diff should be computed once per content change, not per body eval.
    @State private var cachedRows: [LineDiff.Row] = []
    @State private var cachedKey: Int = 0
    @State private var dedentedOld: String?
    @State private var dedentedNew: String = ""
    /// Highlighted text per row id, swapped in when Shiki catches up; rows
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

    var body: some View {
        // No header: the tool-call title already carries the filename and
        // +N/−N counters, so the card is just the code. Long diffs scroll
        // inside it instead of laying the whole file change out on the page.
        // The body paints the theme's editor background — the surface the
        // token colors were designed for (pierre's --diffs-bg).
        // Freshly recycled rows (empty @State) render straight from the
        // shared cache on their first frame; `.task` then re-seeds the local
        // state without recomputing.
        let cached = cachedRows.isEmpty ? DiffRenderCache.shared.entry(for: renderKey) : nil
        let rows = cached?.rows ?? cachedRows
        let highlights = cached?.highlighted ?? highlightedRows
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            let gutterWidth = gutterWidth(for: rows)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row, gutterWidth: gutterWidth, highlights: highlights)
                }
            }
            .padding(.vertical, 4)
            // Row backgrounds run to at least the viewport edge; wider code
            // still scrolls horizontally.
            .frame(minWidth: viewportWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        // Horizontal bounce only when the code is actually wider than the
        // card: an always-bouncing x-axis captures trackpad gestures meant
        // for the page's vertical scroll. Vertical keeps the stock feel.
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        .frame(maxHeight: 320)
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Themed bodies can match the window surface, so the card keeps its
        // shape with a hairline; system themes keep the borderless card.
        .overlay {
            if !theme.isSystem {
                RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: 1)
            }
        }
        .task(id: highlightKey) { await refreshRowsAndHighlight() }
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
            rowText(row, highlights: highlights)
                .textSelection(.enabled)
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

    /// Row text: Shiki-highlighted when the path's language and the theme
    /// allow it, plain otherwise. Blank lines render a space to keep height.
    private func rowText(_ row: LineDiff.Row, highlights: [Int: AttributedString]) -> Text {
        if row.text.isEmpty { return Text(" ") }
        if let highlighted = highlights[row.id] { return Text(highlighted) }
        return Text(row.text)
    }

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
                dedentedOld = entry.dedentedOld
                dedentedNew = entry.dedentedNew
                cachedRows = entry.rows
                highlightedRows = entry.highlighted
                return
            }
            if !cachedRows.isEmpty {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let old = oldText
            let new = newText
            // Strip shared indentation before diffing so mid-file edit
            // snippets aren't pushed right by the source's nesting depth.
            let computed = await Task.detached(priority: .userInitiated) {
                let (dedentedOld, dedentedNew) = LineDiff.dedent(old: old, new: new)
                let rows = LineDiff.rows(old: dedentedOld, new: dedentedNew)
                return (dedentedOld, dedentedNew, rows)
            }.value
            guard !Task.isCancelled else { return }
            cachedKey = key
            (dedentedOld, dedentedNew) = (computed.0, computed.1)
            cachedRows = computed.2
            highlightedRows = [:]
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
