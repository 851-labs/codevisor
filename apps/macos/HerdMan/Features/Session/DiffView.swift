import SwiftUI

/// A compact line-numbered diff for a tool-call file edit. Lines present in the
/// new text but not the old are highlighted as additions; lines only in the old
/// text are shown as removals.
struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String
    @Environment(\.theme) private var theme

    private var rows: [Line] { Self.diff(old: oldText, new: newText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text((path as NSString).lastPathComponent)
                    .font(.caption.monospaced().weight(.semibold))
                Text("+\(rows.filter { $0.kind == .added }.count)")
                    .font(.caption2.monospaced()).foregroundStyle(theme.diffAddedFg)
                Text("-\(rows.filter { $0.kind == .removed }.count)")
                    .font(.caption2.monospaced()).foregroundStyle(theme.diffRemovedFg)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            Text(row.number.map(String.init) ?? "")
                                .frame(width: 34, alignment: .trailing)
                                .foregroundStyle(.tertiary)
                            Text(row.marker)
                                .frame(width: 8)
                                .foregroundStyle(row.kind.tint(theme))
                            Text(row.text.isEmpty ? " " : row.text)
                                .foregroundStyle(row.kind == .removed ? .secondary : .primary)
                            Spacer(minLength: 0)
                        }
                        .font(.caption.monospaced())
                        .padding(.vertical, 1)
                        .padding(.horizontal, 8)
                        .background(row.kind.background(theme))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Diff model

    struct Line: Identifiable {
        enum Kind {
            case context, added, removed
            func tint(_ theme: Theme) -> Color {
                switch self {
                case .context: return .clear
                case .added: return theme.diffAddedFg
                case .removed: return theme.diffRemovedFg
                }
            }
            func background(_ theme: Theme) -> Color {
                switch self {
                case .context: return .clear
                case .added: return theme.diffAddedBg
                case .removed: return theme.diffRemovedBg
                }
            }
        }
        let id = UUID()
        let number: Int?
        let marker: String
        let kind: Kind
        let text: String
    }

    /// A simple line-set diff: lines in new but not old are additions, lines in
    /// old but not new are removals, the rest are context. Good enough for
    /// displaying agent edits without a full LCS.
    static func diff(old: String?, new: String) -> [Line] {
        let newLines = new.components(separatedBy: "\n")
        guard let old, !old.isEmpty else {
            return newLines.enumerated().map { index, text in
                Line(number: index + 1, marker: "+", kind: .added, text: text)
            }
        }
        let oldSet = Set(old.components(separatedBy: "\n"))
        let newSet = Set(newLines)
        var rows: [Line] = []
        // Removals first (lines only in old).
        for text in old.components(separatedBy: "\n") where !newSet.contains(text) {
            rows.append(Line(number: nil, marker: "-", kind: .removed, text: text))
        }
        for (index, text) in newLines.enumerated() {
            let kind: Line.Kind = oldSet.contains(text) ? .context : .added
            rows.append(Line(number: index + 1, marker: kind == .added ? "+" : " ", kind: kind, text: text))
        }
        return rows
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
