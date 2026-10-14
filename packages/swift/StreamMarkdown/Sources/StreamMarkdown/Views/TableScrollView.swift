#if canImport(AppKit)
  import AppKit

  final class TableBleedContainer: NSView {
    let scrollView: TableScrollView
    private(set) var bleed: CGFloat = 0
    var bleedLimit: CGFloat = .greatestFiniteMagnitude {
      didSet {
        guard bleedLimit != oldValue else { return }
        needsLayout = true
      }
    }

    init(tableTextView: TableTextView) {
      scrollView = TableScrollView(tableTextView: tableTextView)
      super.init(frame: .zero)
      addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      bleed = max(0, min(measuredBleed(), bleedLimit.rounded(.down)))
      scrollView.contentInsets = NSEdgeInsets(top: 0, left: bleed, bottom: 0, right: bleed)
      scrollView.frame = bounds.insetBy(dx: -bleed, dy: 0)
      scrollView.needsLayout = true
      scrollView.layoutSubtreeIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let superview else { return nil }
      let local = convert(point, from: superview)
      guard scrollView.frame.contains(local) else { return nil }
      return scrollView.hitTest(local)
    }

    private func measuredBleed() -> CGFloat {
      var ancestor = superview
      while let view = ancestor {
        if let transcript = view as? NSScrollView, transcript !== scrollView {
          let clip = transcript.contentView
          let rect = convert(bounds, to: clip)
          let left = rect.minX - clip.bounds.minX
          let right = clip.bounds.maxX - rect.maxX
          return max(0, min(left, right).rounded(.down))
        }
        ancestor = view.superview
      }
      return 0
    }
  }

  final class TableScrollView: TranscriptHorizontalScrollView {
    let tableTextView: TableTextView
    private let document: TableDocumentView

    init(tableTextView: TableTextView) {
      self.tableTextView = tableTextView
      document = TableDocumentView(tableTextView: tableTextView)
      super.init(frame: .zero)
      drawsBackground = false
      borderType = .noBorder
      hasVerticalScroller = false
      hasHorizontalScroller = true
      scrollerStyle = .overlay
      autohidesScrollers = true
      horizontalScrollElasticity = .automatic
      verticalScrollElasticity = .none
      automaticallyAdjustsContentInsets = false
      documentView = document
    }

    func setBorderColor(_ color: NSColor) {
      document.setBorderColor(color)
    }

    override func layout() {
      super.layout()
      let columnWidth = contentView.bounds.width - contentInsets.left - contentInsets.right
      guard columnWidth > 0 else { return }
      let width = MarkdownTextTableGeometry.width(max(columnWidth, tableTextView.minimumTableWidth))
      let size = NSSize(width: width, height: contentView.bounds.height)
      if tableTextView.frame.size != size {
        tableTextView.setFrameSize(size)
      }
      tableTextView.layoutSubtreeIfNeeded()
      if document.frame.size != size {
        document.setFrameSize(size)
      }
      document.needsLayout = true
    }
  }

  final class TableDocumentView: NSView {
    private let tableTextView: TableTextView

    init(tableTextView: TableTextView) {
      self.tableTextView = tableTextView
      super.init(frame: .zero)
      wantsLayer = true
      layer?.cornerRadius = MarkdownTableMetrics.cornerRadius
      layer?.masksToBounds = true
      layer?.borderWidth = 1
      addSubview(tableTextView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    private var borderColor: NSColor = .separatorColor

    func setBorderColor(_ color: NSColor) {
      guard color != borderColor else { return }
      borderColor = color
      needsDisplay = true
    }

    override func updateLayer() {
      super.updateLayer()
      layer?.borderColor = borderColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
    }

    override func layout() {
      super.layout()
      if tableTextView.frame != bounds { tableTextView.frame = bounds }
    }
  }
#endif
