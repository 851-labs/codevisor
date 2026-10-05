import Foundation

#if canImport(AppKit)
  import AppKit
  typealias MarkdownLoadingHostView = NSTextView
  private typealias PlatformView = NSView
#elseif canImport(UIKit)
  import UIKit
  typealias MarkdownLoadingHostView = UITextView
  private typealias PlatformView = UIView
#endif

extension MarkdownLinkAction {
  /// Activates a link at `index` in `textView`. An inline image there shows
  /// as loading until the host's preview is ready.
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

/// Dims an inline image and shows a spinner over it while the host
/// prepares its preview (for a remote file, a download). It appears only
/// after a short delay, so a preview that opens quickly never flashes it.
@MainActor
enum MarkdownImageLoadingIndicator {
  private static let delay: Duration = .milliseconds(150)

  private struct Key: Hashable {
    let textView: ObjectIdentifier
    let characterIndex: Int
  }

  @MainActor
  private final class Indicator {
    var overlay: PlatformView?
    var isFinished = false

    func finish() {
      isFinished = true
      overlay?.removeFromSuperview()
      overlay = nil
    }
  }

  private static var active: [Key: Indicator] = [:]

  static func track(
    _ preparing: Task<Void, Never>,
    in textView: MarkdownLoadingHostView,
    characterIndex: Int
  ) {
    let key = Key(textView: ObjectIdentifier(textView), characterIndex: characterIndex)
    // A repeat activation replaces the earlier indicator instead of
    // stacking a second scrim over the same image.
    active[key]?.finish()
    let indicator = Indicator()
    active[key] = indicator

    Task { @MainActor [weak textView] in
      try? await Task.sleep(for: delay)
      guard !indicator.isFinished, let textView,
        let rect = imageRect(in: textView, characterIndex: characterIndex)
      else { return }
      let overlay = makeOverlay(frame: rect)
      textView.addSubview(overlay)
      indicator.overlay = overlay
    }
    Task { @MainActor in
      await preparing.value
      indicator.finish()
      if active[key] === indicator { active[key] = nil }
    }
  }

  // MARK: - Geometry

  /// The image attachment's frame in the text view's coordinates.
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

  // MARK: - Overlay

  #if canImport(AppKit)
    /// Leaves clicks and the image's context menu to the text view beneath.
    private final class PassthroughView: NSView {
      override func hitTest(_: NSPoint) -> NSView? { nil }
    }
  #endif

  /// Matches the attachment thumbnail's loading state: a light scrim and a
  /// white spinner on a dark badge, readable over any image.
  private static func makeOverlay(frame: CGRect) -> PlatformView {
    let badgeSize: CGFloat = 28
    #if canImport(AppKit)
      let overlay = PassthroughView(frame: frame)
      overlay.wantsLayer = true
      overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor

      let badge = NSView(
        frame: CGRect(
          x: (frame.width - badgeSize) / 2, y: (frame.height - badgeSize) / 2,
          width: badgeSize, height: badgeSize))
      badge.wantsLayer = true
      badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
      badge.layer?.cornerRadius = badgeSize / 2
      badge.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

      let spinner = NSProgressIndicator(frame: CGRect(x: 6, y: 6, width: 16, height: 16))
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isIndeterminate = true
      spinner.appearance = NSAppearance(named: .darkAqua)
      spinner.setAccessibilityLabel("Loading")
      spinner.startAnimation(nil)
      badge.addSubview(spinner)
      overlay.addSubview(badge)
      return overlay
    #else
      let overlay = UIView(frame: frame)
      overlay.backgroundColor = UIColor.black.withAlphaComponent(0.25)
      overlay.isUserInteractionEnabled = false

      let badge = UIView(
        frame: CGRect(
          x: (frame.width - badgeSize) / 2, y: (frame.height - badgeSize) / 2,
          width: badgeSize, height: badgeSize))
      badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
      badge.layer.cornerRadius = badgeSize / 2
      badge.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]

      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.color = .white
      spinner.center = CGPoint(x: badgeSize / 2, y: badgeSize / 2)
      spinner.accessibilityLabel = "Loading"
      spinner.startAnimating()
      badge.addSubview(spinner)
      overlay.addSubview(badge)
      return overlay
    #endif
  }
}
