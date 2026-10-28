import CoreGraphics

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

@MainActor
enum TranscriptSendSnapshot {
  static func image(of view: TranscriptSendPlatformView) -> CGImage? {
    let root = renderRoot(of: view)
    let rect = root.convert(view.bounds, from: view)
    guard !rect.isEmpty else { return nil }
    return rendered(root, in: rect)
  }

  static func image(of view: TranscriptSendPlatformView, in root: TranscriptSendPlatformView) -> CGImage? {
    let rect = root.convert(view.bounds, from: view)
    guard !rect.isEmpty else { return nil }
    return renderedLayer(root, in: rect)
  }

  private static func renderRoot(of view: TranscriptSendPlatformView) -> TranscriptSendPlatformView {
    var root = view
    while let parent = root.superview, !stopsAt(parent) { root = parent }
    return root
  }

  #if canImport(UIKit)
    private static func stopsAt(_ parent: UIView) -> Bool {
      parent is TranscriptSendTrack || parent is UIWindow
    }

    private static func rendered(_ root: UIView, in rect: CGRect) -> CGImage? {
      image(in: rect) { _ in root.drawHierarchy(in: root.bounds, afterScreenUpdates: false) }
    }

    private static func renderedLayer(_ root: UIView, in rect: CGRect) -> CGImage? {
      root.layoutIfNeeded()
      let opacity = root.layer.opacity
      root.layer.opacity = 1
      defer { root.layer.opacity = opacity }
      return image(in: rect) { context in root.layer.render(in: context.cgContext) }
    }

    private static func image(in rect: CGRect, draw: (UIGraphicsImageRendererContext) -> Void) -> CGImage? {
      let format = UIGraphicsImageRendererFormat.preferred()
      format.opaque = false
      return UIGraphicsImageRenderer(bounds: rect, format: format).image(actions: draw).cgImage
    }
  #else
    private static func stopsAt(_ parent: NSView) -> Bool {
      parent is TranscriptSendTrack || parent === parent.window?.contentView?.superview
    }

    private static func rendered(_ root: NSView, in rect: CGRect) -> CGImage? {
      guard let bitmap = root.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
      root.cacheDisplay(in: rect, to: bitmap)
      return bitmap.cgImage
    }

    private static func renderedLayer(_ root: NSView, in rect: CGRect) -> CGImage? {
      rendered(root, in: rect)
    }
  #endif
}
