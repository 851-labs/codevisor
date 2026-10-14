#if canImport(AppKit)
  import MarkdownCore
  import SwiftUI
  #if canImport(AppKit)
    import AppKit
  #endif

  struct MarkdownTableView: View {
    let headers: [MarkdownText]
    let alignments: [ColumnAlignment]
    let rows: [[MarkdownText]]

    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownImageLoader) private var imageLoader
    @State private var images = MarkdownTableImages()
    @State private var renderMemo = MarkdownTableRenderMemo()
    @State private var usesPreparedLayout: Bool

    init(headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]]) {
      self.headers = headers
      self.alignments = alignments
      self.rows = rows
      _usesPreparedLayout = State(initialValue: rows.count > MarkdownLayoutPolicy.maximumSynchronousTableRows)
    }

    var body: some View {
      let sources = Set((headers + rows.flatMap { $0 }).flatMap(\.imageSources))
      Group {
        if usesPreparedLayout {
          PreparedSelectableTextView(
            headers: headers, alignments: alignments, rows: rows, theme: theme, images: images.resources)
        } else {
          SelectableTextTableView(
            model: TableModel(
              headers: headers,
              alignments: alignments,
              rows: rows,
              theme: theme,
              images: images.resources
            ),
            renderMemo: renderMemo
          )
        }
      }
      .task(id: MarkdownTableImages.Request(sources: sources, loaderID: imageLoader.id)) {
        await images.load(sources: sources, using: imageLoader)
      }
    }
  }

  struct TableModel: Equatable {
    let headers: [MarkdownText]
    let alignments: [ColumnAlignment]
    let rows: [[MarkdownText]]
    let theme: MarkdownTheme
    let images: [String: MarkdownImageResource]
    let contentKey: MarkdownTableRenderCache.ContentKey

    init(
      headers: [MarkdownText],
      alignments: [ColumnAlignment],
      rows: [[MarkdownText]],
      theme: MarkdownTheme,
      images: [String: MarkdownImageResource] = [:]
    ) {
      self.headers = headers
      self.alignments = alignments
      self.rows = rows
      self.theme = theme
      self.images = images
      contentKey = MarkdownTableRenderCache.ContentKey(
        headers: headers,
        alignments: alignments,
        rows: rows,
        themeFingerprint: theme.renderFingerprint,
        images: images
      )
    }

    init(
      headers: [String],
      alignments: [ColumnAlignment],
      rows: [[String]],
      theme: MarkdownTheme
    ) {
      let parser = MarkdownParser()
      self.init(
        headers: headers.map(parser.parseInline),
        alignments: alignments,
        rows: rows.map { $0.map(parser.parseInline) },
        theme: theme
      )
    }

    static func == (lhs: TableModel, rhs: TableModel) -> Bool {
      lhs.contentKey == rhs.contentKey
    }
  }

  struct SelectableTextTableView: NSViewRepresentable {
    let model: TableModel
    let renderMemo: MarkdownTableRenderMemo
    @Environment(\.markdownLinkAction) var linkAction
    @Environment(\.markdownTableBleedLimit) var bleedLimit

    private static let minimumWidth: CGFloat = 180

    func makeCoordinator() -> MarkdownTextViewLinkCoordinator { .init() }

    func makeNSView(context: Context) -> TableBleedContainer {
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
      textView.isVerticallyResizable = false
      textView.isHorizontallyResizable = false
      textView.focusRingType = .none
      textView.linkTextAttributes = [
        .foregroundColor: NSColor.linkColor,
        .cursor: NSCursor.pointingHand,
      ]
      context.coordinator.install(on: textView, action: linkAction)
      textView.update(model: model, renderMemo: renderMemo)
      let bleedContainer = TableBleedContainer(tableTextView: textView)
      bleedContainer.bleedLimit = bleedLimit
      bleedContainer.scrollView.setBorderColor(NSColor(model.theme.tableBorderColor))
      return bleedContainer
    }

    private func layoutWidth(for proposed: CGFloat) -> CGFloat {
      max(proposed, renderMemo.minimumWidth(for: model))
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView container: TableBleedContainer, context _: Context
    ) -> CGSize? {
      guard let proposed = proposal.width, proposed.isFinite else {
        let ideal = container.bounds.width > 1 ? container.bounds.width : 400
        return CGSize(
          width: ideal, height: renderMemo.size(for: model, width: layoutWidth(for: ideal)).height
        )
      }
      if proposed <= 1 {
        return CGSize(
          width: Self.minimumWidth,
          height: renderMemo.size(for: model, width: layoutWidth(for: Self.minimumWidth)).height
        )
      }
      return CGSize(
        width: proposed, height: renderMemo.size(for: model, width: layoutWidth(for: proposed)).height)
    }
  }

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

    func minimumWidth(for model: TableModel) -> CGFloat {
      cache.minimumWidth(for: model)
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
      MarkdownTextTableGeometry.width(width)
    }
  }

  @MainActor
  final class MarkdownTableRenderCache {
    final class ContentKey: Hashable {
      let headers: [MarkdownText]
      let alignments: [ColumnAlignment]
      let rows: [[MarkdownText]]
      let themeFingerprint: Int
      let images: [String: MarkdownImageResource]
      private let digest: Int

      init(
        headers: [MarkdownText],
        alignments: [ColumnAlignment],
        rows: [[MarkdownText]],
        themeFingerprint: Int,
        images: [String: MarkdownImageResource] = [:]
      ) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
        self.themeFingerprint = themeFingerprint
        self.images = images

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
        hasher.combine(images)
        digest = hasher.finalize()
      }

      static func == (lhs: ContentKey, rhs: ContentKey) -> Bool {
        lhs === rhs
          || (lhs.digest == rhs.digest
            && lhs.themeFingerprint == rhs.themeFingerprint
            && lhs.headers == rhs.headers
            && lhs.alignments == rhs.alignments
            && lhs.rows == rhs.rows
            && lhs.images == rhs.images)
      }

      func hash(into hasher: inout Hasher) {
        hasher.combine(digest)
      }
    }

    private struct RenderKey: Hashable {
      let content: ContentKey
      let width: CGFloat
    }

    private struct CellKey: Hashable {
      let markdown: MarkdownText
      let isHeader: Bool
      let themeFingerprint: Int
      let images: [String: MarkdownImageResource]
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
    private var cellInsertionOrder: [CellKey] = []
    private var cellInsertionHead = 0
    private var accessClock: UInt64 = 0

    private let measurementStorage = NSTextStorage()
    private let measurementLayoutManager = NSLayoutManager()
    private let measurementContainer = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )

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

    func minimumWidth(for model: TableModel) -> CGFloat {
      MarkdownTableMetrics.minimumTableWidth(
        columnMinimumWidths: preparedTable(for: model).columnMinimumWidths
      )
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
      let width = Self.normalized(width)
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

    private static func normalized(_ width: CGFloat) -> CGFloat {
      MarkdownTextTableGeometry.width(width)
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
      ) {
        [self, themeFingerprint = model.contentKey.themeFingerprint]
        markdown, isHeader, theme in
        preparedCell(
          markdown,
          isHeader: isHeader,
          theme: theme,
          themeFingerprint: themeFingerprint,
          images: model.images
        )
      }
      preparationCount += 1
      let entry = PreparedEntry(table: prepared, lastAccess: tick())
      preparedEntries[model.contentKey] = entry
      evictOldestPreparedEntryIfNeeded()
      return prepared
    }

    private func preparedCell(
      _ markdown: MarkdownText,
      isHeader: Bool,
      theme: MarkdownTheme,
      themeFingerprint: Int,
      images: [String: MarkdownImageResource]
    ) -> MarkdownTableRenderer.PreparedCell {
      let key = CellKey(
        markdown: markdown,
        isHeader: isHeader,
        themeFingerprint: themeFingerprint,
        images: images.filter { markdown.imageSources.contains($0.key) }
      )
      if let cached = cellEntries[key] {
        return cached.cell
      }

      let cell = MarkdownTableRenderer.prepareResolvedCell(
        markdown,
        isHeader: isHeader,
        theme: theme,
        images: images
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

#endif
