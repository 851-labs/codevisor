import SwiftUI
import HerdManCore

/// A compact line-numbered diff for a tool-call file edit, computed by
/// `LineDiff` (real Myers line diff, git hunk ordering) with old/new gutters.
struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String
    @Environment(\.theme) private var theme

    /// Rows are cached because streamed edits mutate `newText` repeatedly and
    /// the diff should be computed once per content change, not per body eval.
    @State private var cachedRows: [LineDiff.Row] = []
    @State private var cachedKey: Int = 0

    private var contentKey: Int {
        var hasher = Hasher()
        hasher.combine(oldText)
        hasher.combine(newText)
        return hasher.finalize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cachedRows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { refreshRowsIfNeeded() }
        .onChange(of: contentKey) { refreshRowsIfNeeded() }
    }

    private var header: some View {
        let totals = LineDiff.Totals(
            added: cachedRows.filter { $0.kind == .added }.count,
            removed: cachedRows.filter { $0.kind == .removed }.count
        )
        return HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent)
                .font(.caption.monospaced().weight(.semibold))
            Text("+\(totals.added)")
                .font(.caption2.monospaced()).foregroundStyle(theme.diffAddedFg)
            Text("−\(totals.removed)")
                .font(.caption2.monospaced()).foregroundStyle(theme.diffRemovedFg)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func rowView(_ row: LineDiff.Row) -> some View {
        HStack(spacing: 8) {
            Text(row.oldLine.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(row.newLine.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(marker(for: row.kind))
                .frame(width: 8)
                .foregroundStyle(tint(for: row.kind))
            rowText(row)
                .foregroundStyle(row.kind == .removed ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.caption.monospaced())
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(background(for: row.kind))
    }

    /// The single seam for row text rendering (future syntax highlighting).
    private func rowText(_ row: LineDiff.Row) -> Text {
        Text(row.text.isEmpty ? " " : row.text)
    }

    private func refreshRowsIfNeeded() {
        let key = contentKey
        guard key != cachedKey || cachedRows.isEmpty else { return }
        cachedKey = key
        cachedRows = LineDiff.rows(old: oldText, new: newText)
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
        path: "packages/cli/src/index.ts",
        oldText: "\"ConnectTimeout=10\",\n`${session.user}@${session.host}`,",
        newText: "\"ConnectTimeout=10\",\n...(shellCommand ? [] : [\"-tt\"]),\n`${session.user}@${session.host}`,"
    )
    .padding()
    .frame(width: 520)
}
