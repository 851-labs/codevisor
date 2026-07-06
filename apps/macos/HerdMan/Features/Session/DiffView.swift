import CodeHighlighter
import HerdManCore
import SwiftUI

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
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            let gutterWidth = gutterWidth
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cachedRows) { row in
                    rowView(row, gutterWidth: gutterWidth)
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
        .onAppear { refreshRowsIfNeeded() }
        .onChange(of: contentKey) { refreshRowsIfNeeded() }
        .task(id: highlightKey) { await highlightRows() }
    }

    /// Gutters sized to the widest line number instead of a fixed column —
    /// a 6-line diff shouldn't reserve space for five-digit files.
    private var gutterWidth: CGFloat {
        let maxLine = cachedRows.reduce(1) { partial, row in
            max(partial, row.oldLine ?? 0, row.newLine ?? 0)
        }
        return CGFloat(max(2, String(maxLine).count)) * 7
    }

    private func rowView(_ row: LineDiff.Row, gutterWidth: CGFloat) -> some View {
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
            rowText(row)
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
    private func rowText(_ row: LineDiff.Row) -> Text {
        if row.text.isEmpty { return Text(" ") }
        if let highlighted = highlightedRows[row.id] { return Text(highlighted) }
        return Text(row.text)
    }

    private func refreshRowsIfNeeded() {
        let key = contentKey
        guard key != cachedKey || cachedRows.isEmpty else { return }
        cachedKey = key
        // Strip shared indentation before diffing so mid-file edit snippets
        // aren't pushed to the right by the source's nesting depth.
        (dedentedOld, dedentedNew) = LineDiff.dedent(old: oldText, new: newText)
        cachedRows = LineDiff.rows(old: dedentedOld, new: dedentedNew)
        highlightedRows = [:]
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
        // Streamed edits rewrite newText rapidly; task(id:) cancellation
        // makes this a trailing-edge debounce keeping Shiki off the hot path.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        refreshRowsIfNeeded()
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
