#if canImport(AppKit)
  import AppKit
#endif
import CodevisorCore
import StreamMarkdown
import SwiftUI

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

public struct DiffView: View {
  let path: String
  let oldText: String?
  let newText: String
  @Environment(\.codeHighlightTheme) private var highlightTheme
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

  @State private var cachedRows: [LineDiff.Row] = []
  @State private var cachedKey: Int = 0
  @State private var hasPreparedStructure = false
  @State private var dedentedOld: String?
  @State private var dedentedNew: String = ""
  @State private var highlightedRows: [Int: AttributedString] = [:]
  @State private var viewportWidth: CGFloat = 0

  private var contentKey: Int {
    var hasher = Hasher()
    hasher.combine(oldText)
    hasher.combine(newText)
    return hasher.finalize()
  }

  public var body: some View {
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
    .background(.quaternary.opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(Color.separatorColor, lineWidth: 1)
    }
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
      NativeDiffView(
        rows: rows,
        highlights: highlights,
        revision: "\(highlightKey)|\(highlights.count)"
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativeDiffView(
        rows: rows,
        highlights: highlights,
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

  private func lineNumberColor(for kind: LineDiff.Row.Kind) -> Color {
    switch kind {
    case .context: .tertiaryLabelColor
    case .added: .green
    case .removed: .red
    }
  }

  #if !canImport(AppKit) && !canImport(UIKit)
    private func portableRowText(
      _ row: LineDiff.Row,
      highlights: [Int: AttributedString]
    ) -> AttributedString {
      guard let highlighted = highlights[row.id], !row.text.isEmpty else {
        var plain = AttributedString(row.text.isEmpty ? " " : row.text)
        plain.foregroundColor = Color.primary
        return plain
      }
      var result = AttributedString()
      for run in highlighted.runs {
        var piece = AttributedString(highlighted[run.range])
        if piece.foregroundColor == nil {
          piece.foregroundColor = Color.primary
        }
        result += piece
      }
      return result
    }
  #endif

  #if canImport(AppKit) || canImport(UIKit)
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
            .foregroundColor: OSColor(Color.primary),
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
                ?? OSColor(Color.primary),
            ]
          )
        )
      }
      return result
    }
  #endif

  private func refreshRowsAndHighlight() async {
    let key = contentKey
    if key != cachedKey || cachedRows.isEmpty {
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
    let highlights = await DiffHighlighting.highlights(
      rows: cachedRows, old: dedentedOld, new: dedentedNew, path: path, theme: highlightTheme)
    guard !Task.isCancelled else { return }
    highlightedRows = highlights
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
    case .added: .green
    case .removed: .red
    }
  }

  private func background(for kind: LineDiff.Row.Kind) -> Color {
    switch kind {
    case .context: .clear
    case .added: .green.opacity(0.12)
    case .removed: .red.opacity(0.12)
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
