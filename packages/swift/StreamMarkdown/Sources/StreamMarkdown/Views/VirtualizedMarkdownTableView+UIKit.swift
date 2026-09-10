#if canImport(UIKit) && !canImport(AppKit)
  import MarkdownCore
  import SwiftUI
  import UIKit

  /// The table keeps one horizontal coordinate space. Only cells intersecting
  /// the enclosing transcript viewport own native text views.
  struct VirtualizedMarkdownTableView: View {
    let headers: [MarkdownText]
    let alignments: [ColumnAlignment]
    let rows: [[MarkdownText]]
    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownTableBleed) private var bleed
    @Environment(\.streamMarkdownTextLayoutWidth) private var rowWidth
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredWidth: CGFloat = 320
    @State private var prepared: UIKitMarkdownTableLayout?
    @State private var preparedKey: RequestKey?

    private struct RequestKey: Hashable, Sendable {
      let headers: [MarkdownText]
      let alignments: [ColumnAlignment]
      let rows: [[MarkdownText]]
      let theme: Int
      let width: CGFloat
      let dynamicTypeSize: DynamicTypeSize
      let dark: Bool
    }

    private struct Request: Sendable {
      let key: RequestKey
      let theme: MarkdownTheme
      let traits: MarkdownRenderingTraits
    }

    @State private var worker = LatestValuePreparationWorker<Request, UIKitMarkdownTableLayout> { request in
      try request.traits.perform {
        try UIKitMarkdownTableLayout(
          headers: request.key.headers, alignments: request.key.alignments, rows: request.key.rows,
          theme: request.theme, width: request.key.width
        )
      }
    }

    var body: some View {
      let key = RequestKey(
        headers: headers, alignments: alignments, rows: rows, theme: theme.renderFingerprint,
        width: rowWidth.flatMap { $0 > 1 ? $0 : nil } ?? measuredWidth,
        dynamicTypeSize: dynamicTypeSize, dark: colorScheme == .dark
      )
      NativeVirtualizedTableView(layout: prepared, theme: theme, bleed: bleed, linkAction: linkAction)
        .frame(height: prepared?.geometry.size.height ?? CGFloat(rows.count + 1) * 44)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
          if width > bleed * 2 + 1 { measuredWidth = width - bleed * 2 }
        }
        // A usable published snapshot can be shown while a newer stream
        // revision is preparing. Waiting for exact equality would keep a
        // continuously growing table hidden until generation stops.
        .preference(key: ContentLayoutReadinessPreferenceKey.self, value: prepared == nil ? 1 : 0)
        .task(id: key) {
          guard preparedKey != key else { return }
          let traits = MarkdownRenderingTraits(dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme)
          worker.submit(Request(key: key, theme: theme, traits: traits)) { request, result in
            switch result {
            case let .success(layout):
              prepared = layout
              preparedKey = request.key
            case .failure(is CancellationError):
              break
            case let .failure(error):
              assertionFailure("Unexpected table preparation failure: \(error)")
            }
          }
        }
        .onDisappear { worker.cancel() }

    }
  }

  private struct NativeVirtualizedTableView: UIViewControllerRepresentable {
    let layout: UIKitMarkdownTableLayout?
    let theme: MarkdownTheme
    let bleed: CGFloat
    let linkAction: MarkdownLinkAction?

    func makeUIViewController(context: Context) -> NativeVirtualizedTableController {
      let controller = NativeVirtualizedTableController()
      updateUIViewController(controller, context: context)
      return controller
    }

    func updateUIViewController(_ controller: NativeVirtualizedTableController, context: Context) {
      controller.tableView.configure(layout: layout, theme: theme, bleed: bleed, linkAction: linkAction)
    }
  }

  private final class NativeVirtualizedTableController: UIViewController {
    let tableView = VirtualizedTableView()

    override func loadView() { view = tableView }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      tableView.updateViewport()
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      tableView.updateViewport()
    }
  }

  @MainActor
  final class VirtualizedTableView: UIView, UIScrollViewDelegate, UITextViewDelegate {
    private let horizontalScrollView = UIScrollView()
    private let document = UIView()
    private let headerFill = CALayer()
    private let border = CAShapeLayer()
    private var cells: [Int: SelectableTextKitView] = [:]
    private var reusableCells: [SelectableTextKitView] = []
    private var rules: [Int: CALayer] = [:]
    private var borderColor = UIColor.separator
    private var linkAction: MarkdownLinkAction?
    private weak var transcript: UIScrollView?
    private var viewportObservation: NSKeyValueObservation?
    private var viewportUpdateScheduled = false
    private weak var visibleLayout: UIKitMarkdownTableLayout?
    private var visibleOriginY: CGFloat = 0
    private(set) var tableLayout: UIKitMarkdownTableLayout?

    init() {
      super.init(frame: .zero)
      horizontalScrollView.delegate = self
      horizontalScrollView.showsHorizontalScrollIndicator = false
      horizontalScrollView.showsVerticalScrollIndicator = false
      horizontalScrollView.alwaysBounceVertical = false
      horizontalScrollView.isDirectionalLockEnabled = true
      horizontalScrollView.contentInsetAdjustmentBehavior = .never
      addSubview(horizontalScrollView)
      document.backgroundColor = .clear
      // Keep the potentially enormous document out of an offscreen rounded
      // mask. Cell padding stays inside the border; only the short header
      // fill needs rounded clipping.
      headerFill.cornerRadius = MarkdownTableMetrics.cornerRadius
      headerFill.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      document.layer.addSublayer(headerFill)
      border.fillColor = nil
      border.lineWidth = 1
      document.layer.addSublayer(border)
      document.clipsToBounds = true
      horizontalScrollView.addSubview(document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
      layout: UIKitMarkdownTableLayout?, theme: MarkdownTheme, bleed: CGFloat,
      linkAction: MarkdownLinkAction?
    ) {
      self.linkAction = linkAction
      borderColor = UIColor(theme.tableBorderColor)
      let insets = UIEdgeInsets(top: 0, left: bleed, bottom: 0, right: bleed)
      if horizontalScrollView.contentInset != insets {
        horizontalScrollView.contentInset = insets
        setNeedsLayout()
      }
      guard tableLayout !== layout else { return }
      let first = tableLayout == nil
      tableLayout = layout
      if first { horizontalScrollView.contentOffset.x = -bleed }
      setNeedsLayout()
      requestViewportUpdate()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      viewportObservation = nil
      transcript = nil
      guard window != nil else { return }
      var ancestor = superview
      while let view = ancestor {
        if let scroll = view as? UIScrollView,
          scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.height
        {
          transcript = scroll
          viewportObservation = scroll.observe(\.bounds) { [weak self] _, _ in
            // Offset notifications can arrive before the transcript has
            // positioned its row hosts. Resolve coordinates in layout,
            // after those ancestor frames have reached their final values.
            MainActor.assumeIsolated { self?.requestViewportUpdate() }
          }
          break
        }
        ancestor = view.superview
      }
      setNeedsLayout()
      requestViewportUpdate()
    }

    private func requestViewportUpdate() {
      guard !viewportUpdateScheduled else { return }
      viewportUpdateScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        viewportUpdateScheduled = false
        guard window != nil else { return }
        // UIKit can skip layout of a giant row whose origin is far off
        // screen. A coalesced update after containment/layout changes
        // refreshes its visible descendants even when its frame is stable.
        updateViewport()
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateViewport()
    }

    /// The semantic row keeps its full height, but the actual horizontal
    /// scroller and TextKit canvases stay close to the outer viewport. A
    /// document-sized nested UIScrollView gives UIKit an enormous visible
    /// region and can leave its tiled text layers unpainted.
    fileprivate func updateViewport() {
      guard let tableLayout else { return }
      let size = tableLayout.geometry.size
      let visible: CGRect
      if let transcript {
        visible = MarkdownTableGeometry.viewport(in: bounds, visible: convert(transcript.bounds, from: transcript))
      } else {
        visible = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, 640))
      }
      guard !visible.isNull, !visible.isEmpty else {
        horizontalScrollView.isHidden = true
        return
      }
      horizontalScrollView.isHidden = false
      visibleOriginY = visible.minY
      let viewport = CGRect(x: 0, y: visible.minY, width: bounds.width, height: visible.height)
      if horizontalScrollView.frame != viewport { horizontalScrollView.frame = viewport }
      let documentSize = CGSize(width: size.width, height: visible.height)
      if horizontalScrollView.contentSize != documentSize { horizontalScrollView.contentSize = documentSize }
      document.frame = CGRect(origin: .zero, size: documentSize)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      headerFill.frame = CGRect(x: 0, y: -visibleOriginY, width: size.width, height: tableLayout.geometry.rowOffsets[1])
      headerFill.backgroundColor =
        UIColor.label.withAlphaComponent(MarkdownTableMetrics.headerBackgroundOpacity).cgColor
      border.frame = document.bounds
      border.path =
        UIBezierPath(
          roundedRect: CGRect(x: 0, y: -visibleOriginY, width: size.width, height: size.height).insetBy(
            dx: 0.5, dy: 0.5),
          cornerRadius: MarkdownTableMetrics.cornerRadius
        ).cgPath
      border.strokeColor = borderColor.cgColor
      CATransaction.commit()
      updateVisibleCells()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisibleCells() }

    private func updateVisibleCells() {
      guard let tableLayout else { return }
      let geometry = tableLayout.geometry
      let visible = CGRect(
        x: horizontalScrollView.contentOffset.x - 40, y: visibleOriginY,
        width: horizontalScrollView.bounds.width + 80, height: horizontalScrollView.bounds.height
      )
      let rowRange = geometry.rows(intersecting: visible)
      let columns = geometry.columns(intersecting: visible)
      let contentChanged = visibleLayout !== tableLayout
      visibleLayout = tableLayout
      let columnCount = geometry.columnOffsets.count - 1
      var required: Set<Int> = []
      for row in rowRange {
        for column in columns {
          let id = row * columnCount + column
          required.insert(id)
          let cell: SelectableTextKitView
          if let existing = cells[id] {
            cell = existing
          } else {
            cell = reusableCells.popLast() ?? SelectableTextKitView()
            cell.delegate = self
            cells[id] = cell
            document.addSubview(cell)
          }
          let frame = geometry.frame(row: row, column: column).insetBy(
            dx: MarkdownTableMetrics.horizontalPadding, dy: MarkdownTableMetrics.verticalPadding
          )
          cell.frame = frame.offsetBy(dx: 0, dy: -visibleOriginY)
          if contentChanged || cell.textStorage.length == 0 {
            cell.setContent(tableLayout.cells[row][column])
            _ = cell.contentHeight(forWidth: frame.width)
          }
        }
      }
      for (id, cell) in cells
      where !required.contains(id)
        && (!cell.isFirstResponder || cell.selectedRange.length == 0 || id >= tableLayout.cells.count * columnCount)
      {
        cell.removeFromSuperview()
        cells[id] = nil
        cell.selectedRange = NSRange(location: 0, length: 0)
        if reusableCells.count < 96 {
          cell.setContent(NSAttributedString())
          reusableCells.append(cell)
        }
      }
      document.accessibilityElements = cells.keys.sorted().compactMap { cells[$0] }
      updateRules(rows: rowRange, geometry: geometry)
    }

    private func updateRules(rows: Range<Int>, geometry: MarkdownTableGeometry) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for row in rows where row + 1 < geometry.rowOffsets.count - 1 {
        let rule = rules[row] ?? CALayer()
        if rules[row] == nil { document.layer.addSublayer(rule); rules[row] = rule }
        rule.frame = CGRect(
          x: 0, y: geometry.rowOffsets[row + 1] - visibleOriginY - 1, width: geometry.size.width, height: 1)
        rule.backgroundColor = borderColor.cgColor
      }
      for (row, rule) in rules where !rows.contains(row) {
        rule.removeFromSuperlayer()
        rules[row] = nil
      }
      CATransaction.commit()
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
      guard case let .link(url) = textItem.content, let linkAction else { return defaultAction }
      return linkAction(url) ? UIAction { _ in } : defaultAction
    }
  }
#endif
