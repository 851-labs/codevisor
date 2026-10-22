#if canImport(AppKit)
  import AppKit

  final class StaticTextHighlightLayer: CALayer {
    private let selection = CAShapeLayer()
    private let otherMatches = CAShapeLayer()
    private let currentMatch = CAShapeLayer()
    private let linkUnderline = CAShapeLayer()

    override init() {
      super.init()
      anchorPoint = .zero
      [otherMatches, currentMatch, selection, linkUnderline].forEach { shape in
        shape.anchorPoint = .zero
        addSublayer(shape)
      }
    }

    override init(layer: Any) {
      super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func update(
      in prepared: PreparedStaticText,
      selection range: NSRange?,
      find: TranscriptFindHighlights?,
      hoveredLink: NSRange?,
      isKeyWindow: Bool,
      appearance: NSAppearance
    ) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      [selection, otherMatches, currentMatch, linkUnderline].forEach { $0.frame = bounds }
      appearance.performAsCurrentDrawingAppearance {
        selection.fillColor = StaticTextHighlightColors.selection(isKeyWindow: isKeyWindow).cgColor
        otherMatches.fillColor = StaticTextHighlightColors.match(isCurrent: false, appearance: appearance).cgColor
        currentMatch.fillColor = StaticTextHighlightColors.match(isCurrent: true, appearance: appearance).cgColor
        linkUnderline.fillColor = NSColor.linkColor.cgColor
      }
      linkUnderline.path = hoveredLink.map {
        Self.path(StaticTextHitTesting.underlineRects(in: prepared, for: $0), rounded: false)
      }
      selection.path = range.map { Self.path(StaticTextHitTesting.rects(in: prepared, for: $0), rounded: false) }
      otherMatches.path = Self.path(Self.matchRects(in: prepared, find: find, current: false), rounded: true)
      currentMatch.path = Self.path(Self.matchRects(in: prepared, find: find, current: true), rounded: true)
      CATransaction.commit()
    }

    @MainActor
    func drawInline(
      in prepared: PreparedStaticText, selection range: NSRange?, find: TranscriptFindHighlights?, hoveredLink: NSRange?
    ) {
      if let hoveredLink {
        NSColor.linkColor.setFill()
        StaticTextHitTesting.underlineRects(in: prepared, for: hoveredLink).forEach { $0.fill() }
      }
      let appearance = NSAppearance.currentDrawing()
      StaticTextHighlightColors.match(isCurrent: false, appearance: appearance).setFill()
      Self.matchRects(in: prepared, find: find, current: false).forEach { Self.roundedPath($0).fill() }
      StaticTextHighlightColors.match(isCurrent: true, appearance: appearance).setFill()
      Self.matchRects(in: prepared, find: find, current: true).forEach { Self.roundedPath($0).fill() }
      guard let range else { return }
      StaticTextHighlightColors.selection(isKeyWindow: true).setFill()
      StaticTextHitTesting.rects(in: prepared, for: range).forEach { $0.fill() }
    }

    @MainActor
    private static func matchRects(
      in prepared: PreparedStaticText, find: TranscriptFindHighlights?, current: Bool
    ) -> [NSRect] {
      guard let find else { return [] }
      return find.ranges.enumerated()
        .filter { ($0.offset == find.currentIndex) == current }
        .flatMap { StaticTextHitTesting.rects(in: prepared, for: $0.element) }
    }

    private static func path(_ rects: [NSRect], rounded: Bool) -> CGPath {
      let path = CGMutablePath()
      for rect in rects {
        if rounded {
          path.addRoundedRect(in: rect.insetBy(dx: -1, dy: 0), cornerWidth: 3, cornerHeight: 3)
        } else {
          path.addRect(rect)
        }
      }
      return path
    }

    private static func roundedPath(_ rect: NSRect) -> NSBezierPath {
      NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3)
    }
  }

  enum StaticTextHighlightColors {
    static func selection(isKeyWindow: Bool) -> NSColor {
      isKeyWindow ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    static func match(isCurrent: Bool, appearance: NSAppearance) -> NSColor {
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return isCurrent
        ? .systemOrange.withAlphaComponent(isDark ? 0.75 : 0.85)
        : .systemYellow.withAlphaComponent(isDark ? 0.35 : 0.5)
    }
  }
#endif
