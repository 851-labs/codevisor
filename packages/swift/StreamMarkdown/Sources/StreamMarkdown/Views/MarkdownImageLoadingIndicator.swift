import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
  typealias MarkdownLoadingHostView = NSTextView
#elseif canImport(UIKit)
  import UIKit
  typealias MarkdownLoadingHostView = UITextView
#endif

extension MarkdownLinkAction {
  @MainActor
  func activate(_ url: URL, in textView: MarkdownLoadingHostView, at index: Int) -> Bool {
    #if canImport(AppKit)
      let isImage = textView.textStorage?.streamMarkdownHasImage(at: index) ?? false
    #else
      let isImage = textView.textStorage.streamMarkdownHasImage(at: index)
    #endif
    return activate(url, isImage: isImage) { [weak textView] preparing in
      guard let textView else { return }
      MarkdownImageLoadingIndicator.track(preparing, in: textView, characterIndex: index)
    }
  }
}

@MainActor
enum MarkdownImageLoadingIndicator {
  private struct Key: Hashable {
    let textView: ObjectIdentifier
    let characterIndex: Int
  }

  @MainActor
  private final class Indicator {
    #if canImport(AppKit)
      let view: NSView
    #else
      let host: UIHostingController<AttachmentLoadingOverlay>
      var view: UIView { host.view }
    #endif

    init(frame: CGRect) {
      #if canImport(AppKit)
        let container = PassthroughView(frame: frame)
        let hosting = NSHostingView(rootView: AttachmentLoadingOverlay(isLoading: true))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        view = container
      #else
        host = UIHostingController(rootView: AttachmentLoadingOverlay(isLoading: true))
        host.view.frame = frame
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.safeAreaRegions = []
      #endif
    }

    func remove() { view.removeFromSuperview() }
  }

  #if canImport(AppKit)
    private final class PassthroughView: NSView {
      override func hitTest(_: NSPoint) -> NSView? { nil }
    }
  #endif

  private static var active: [Key: Indicator] = [:]

  static func track(
    _ preparing: Task<Void, Never>,
    in textView: MarkdownLoadingHostView,
    characterIndex: Int
  ) {
    guard let rect = imageRect(in: textView, characterIndex: characterIndex) else { return }
    let key = Key(textView: ObjectIdentifier(textView), characterIndex: characterIndex)
    active[key]?.remove()
    let indicator = Indicator(frame: rect)
    textView.addSubview(indicator.view)
    active[key] = indicator

    Task { @MainActor in
      await preparing.value
      indicator.remove()
      if active[key] === indicator { active[key] = nil }
    }
  }

  private static func imageRect(
    in textView: MarkdownLoadingHostView,
    characterIndex: Int
  ) -> CGRect? {
    let range = NSRange(location: characterIndex, length: 1)
    var rect: CGRect?
    if let textLayoutManager = textView.textLayoutManager {
      rect = segmentRect(in: textLayoutManager, range: range)
    } else {
      #if canImport(AppKit)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
          let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
          rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        }
      #else
        let glyphs = textView.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        rect = textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
      #endif
    }
    guard let rect, rect.width > 1, rect.height > 1 else { return nil }
    #if canImport(AppKit)
      let origin = textView.textContainerOrigin
    #else
      let origin = CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
    #endif
    return rect.offsetBy(dx: origin.x, dy: origin.y)
  }

  private static func segmentRect(in layoutManager: NSTextLayoutManager, range: NSRange) -> CGRect? {
    guard let content = layoutManager.textContentManager,
      let start = content.location(content.documentRange.location, offsetBy: range.location),
      let end = content.location(start, offsetBy: range.length),
      let textRange = NSTextRange(location: start, end: end)
    else { return nil }
    layoutManager.ensureLayout(for: textRange)
    var result: CGRect?
    layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
      result = result.map { $0.union(frame) } ?? frame
      return true
    }
    return result
  }
}
