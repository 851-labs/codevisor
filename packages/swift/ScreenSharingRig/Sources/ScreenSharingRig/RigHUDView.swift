#if os(macOS)
  import AppKit

  /// Translucent monospaced overlay anchored to the top-left of its superview.
  /// It is a sibling of the Metal view, never part of the render pass.
  @MainActor
  final class RigHUDView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let padding: CGFloat = 8

    init() {
      super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
      wantsLayer = true
      layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
      layer?.cornerRadius = 6
      label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      label.textColor = .white
      label.maximumNumberOfLines = 0
      label.lineBreakMode = .byClipping
      label.isSelectable = false
      addSubview(label)
      autoresizingMask = [.minYMargin, .maxXMargin]
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(lines: [String]) {
      label.stringValue = lines.joined(separator: "\n")
      label.sizeToFit()
      let size = NSSize(width: label.frame.width + padding * 2, height: label.frame.height + padding * 2)
      label.frame.origin = NSPoint(x: padding, y: padding)
      guard let superview else { return }
      frame = NSRect(
        x: padding, y: superview.bounds.height - size.height - padding, width: size.width, height: size.height)
    }
  }
#endif
