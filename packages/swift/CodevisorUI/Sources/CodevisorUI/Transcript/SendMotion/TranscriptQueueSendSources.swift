import SwiftUI

#if canImport(UIKit)
  import UIKit
  typealias TranscriptSendPlatformWindow = UIWindow
#else
  import AppKit
  typealias TranscriptSendPlatformWindow = NSWindow
#endif

@MainActor
public final class TranscriptQueueSendSources {
  public static let shared = TranscriptQueueSendSources()

  private struct Source {
    weak var window: TranscriptSendPlatformWindow?
    let rect: CGRect
    let text: String
  }

  private static let retainedSources = 64

  private var sources: [String: Source] = [:]

  public func stageFlight(
    for messageID: UUID,
    session: ObjectIdentifier,
    bubble: Color,
    revealsBubbleInFlight: Bool = false
  ) {
    guard let source = sources.removeValue(forKey: messageID.uuidString.lowercased()),
      let window = source.window, let root = Self.root(of: window)
    else { return }
    TranscriptSendStaging.shared.stage(
      session: session,
      from: root,
      textRect: Self.rect(source.rect, in: root),
      text: Self.bubbleText(source.text),
      bubble: bubble,
      revealsBubbleInFlight: revealsBubbleInFlight
    )
  }

  func record(id: String, text: String, view: TranscriptSendPlatformView) {
    guard let window = view.window, !view.bounds.isEmpty else { return }
    if sources.count >= Self.retainedSources { sources.removeAll() }
    sources[id.lowercased()] = Source(window: window, rect: view.convert(view.bounds, to: nil), text: text)
  }

  #if canImport(UIKit)
    private static func root(of window: UIWindow) -> UIView? { window }

    private static func rect(_ rect: CGRect, in root: UIView) -> CGRect { rect }

    private static func bubbleText(_ text: String) -> NSAttributedString {
      NSAttributedString(
        string: text,
        attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
    }
  #else
    private static func root(of window: NSWindow) -> NSView? { window.contentView }

    private static func rect(_ rect: CGRect, in root: NSView) -> CGRect { root.convert(rect, from: nil) }

    private static func bubbleText(_ text: String) -> NSAttributedString {
      NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor])
    }
  #endif
}

#if canImport(UIKit)
  public struct TranscriptQueueSendAnchor: UIViewRepresentable {
    let id: String
    let text: String

    public init(id: String, text: String) {
      self.id = id
      self.text = text
    }

    public func makeUIView(context _: Context) -> TranscriptQueueSendAnchorView {
      TranscriptQueueSendAnchorView(id: id, text: text)
    }

    public func updateUIView(_ view: TranscriptQueueSendAnchorView, context _: Context) {
      view.update(id: id, text: text)
    }
  }

  public final class TranscriptQueueSendAnchorView: UIView {
    private var id: String
    private var text: String

    init(id: String, text: String) {
      self.id = id
      self.text = text
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(id: String, text: String) {
      self.id = id
      self.text = text
      record()
    }

    override public func layoutSubviews() {
      super.layoutSubviews()
      record()
    }

    override public func willMove(toWindow newWindow: UIWindow?) {
      if newWindow == nil { record() }
      super.willMove(toWindow: newWindow)
    }

    private func record() {
      TranscriptQueueSendSources.shared.record(id: id, text: text, view: self)
    }
  }
#else
  public struct TranscriptQueueSendAnchor: NSViewRepresentable {
    let id: String
    let text: String

    public init(id: String, text: String) {
      self.id = id
      self.text = text
    }

    public func makeNSView(context _: Context) -> TranscriptQueueSendAnchorView {
      TranscriptQueueSendAnchorView(id: id, text: text)
    }

    public func updateNSView(_ view: TranscriptQueueSendAnchorView, context _: Context) {
      view.update(id: id, text: text)
    }
  }

  public final class TranscriptQueueSendAnchorView: NSView {
    private var id: String
    private var text: String

    init(id: String, text: String) {
      self.id = id
      self.text = text
      super.init(frame: .zero)
      setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_: NSPoint) -> NSView? { nil }

    func update(id: String, text: String) {
      self.id = id
      self.text = text
      record()
    }

    override public func layout() {
      super.layout()
      record()
    }

    override public func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      record()
    }

    override public func setFrameOrigin(_ newOrigin: NSPoint) {
      super.setFrameOrigin(newOrigin)
      record()
    }

    override public func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      record()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { record() }
      super.viewWillMove(toWindow: newWindow)
    }

    private func record() {
      TranscriptQueueSendSources.shared.record(id: id, text: text, view: self)
    }
  }
#endif
