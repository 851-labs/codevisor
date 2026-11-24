import SwiftUI

#if canImport(AppKit)
  import AppKit

  struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> ZoomableImageScrollView { ZoomableImageScrollView() }

    func updateNSView(_ view: ZoomableImageScrollView, context: Context) { view.show(image) }
  }

  @MainActor
  final class ZoomableImageScrollView: NSScrollView {
    private let imageView = ZoomableImageContentView()
    private var fitsBounds = true
    private var fittedSize = CGSize.zero
    private var pan: Pan?
    private var gestureMonitor: Any?

    private struct Pan {
      let pointer: CGPoint
      let origin: CGPoint
    }

    private static let maximumZoom: CGFloat = 8
    private static let zoomedInScale: CGFloat = 2
    private static let fitTolerance: CGFloat = 0.01

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      drawsBackground = false
      borderType = .noBorder
      hasVerticalScroller = true
      hasHorizontalScroller = true
      autohidesScrollers = true
      maxMagnification = Self.maximumZoom
      contentView = CenteringClipView()
      contentView.drawsBackground = false
      imageView.imageScaling = .scaleAxesIndependently
      imageView.animates = true
      documentView = imageView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: NSImage) {
      guard imageView.image !== image else { return }

      imageView.image = image
      imageView.frame = CGRect(origin: .zero, size: image.size)
      fitsBounds = true
      fittedSize = .zero
      needsLayout = true
    }

    override func layout() {
      super.layout()
      guard fitsBounds, fittedSize != bounds.size, bounds.width > 0, bounds.height > 0 else { return }

      fittedSize = bounds.size
      minMagnification = min(fitScale, 1)
      magnification = fitScale
    }

    override func mouseDown(with event: NSEvent) {
      let point = imageView.convert(event.locationInWindow, from: nil)
      if event.clickCount == 2, imageView.bounds.contains(point) { return toggleZoom(at: point) }

      pan = Pan(pointer: event.locationInWindow, origin: contentView.bounds.origin)
    }

    override func mouseDragged(with event: NSEvent) {
      guard let pan else { return }

      let moved = CGPoint(
        x: pan.origin.x - (event.locationInWindow.x - pan.pointer.x) / magnification,
        y: pan.origin.y - (event.locationInWindow.y - pan.pointer.y) / magnification)
      contentView.scroll(
        to: contentView.constrainBoundsRect(CGRect(origin: moved, size: contentView.bounds.size)).origin)
      reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
      pan = nil
    }

    private var fitScale: CGFloat {
      let size = imageView.frame.size
      guard size.width > 0, size.height > 0 else { return 1 }
      return min(bounds.width / size.width, bounds.height / size.height, 1)
    }

    private func toggleZoom(at point: CGPoint) {
      let zoomedIn = max(1, fitScale * Self.zoomedInScale)
      fitsBounds.toggle()
      animator().setMagnification(fitsBounds ? fitScale : zoomedIn, centeredAt: point)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
      gestureMonitor = nil
      guard window != nil else { return }

      gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { [weak self] event in
        self?.zoom(with: event) == true ? nil : event
      }
    }

    private func zoom(with event: NSEvent) -> Bool {
      guard let pointer = pointerOverImage(for: event) else { return false }
      if event.type == .smartMagnify {
        toggleZoom(at: pointer)
        return true
      }

      let scale = min(max(magnification * (1 + event.magnification), minMagnification), maxMagnification)
      setMagnification(scale, centeredAt: pointer)
      fitsBounds = abs(magnification - fitScale) < Self.fitTolerance
      return true
    }

    private func pointerOverImage(for event: NSEvent) -> CGPoint? {
      guard let window, let location = location(of: event, in: window) else { return nil }

      let target = window.contentView?.superview?.hitTest(location)
      guard target?.isDescendant(of: self) == true else { return nil }
      return imageView.convert(location, from: nil)
    }

    private func location(of event: NSEvent, in window: NSWindow) -> CGPoint? {
      if event.window === window { return event.locationInWindow }
      guard event.window == nil else { return nil }
      return window.convertPoint(fromScreen: event.locationInWindow)
    }
  }

  private final class ZoomableImageContentView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
      var rect = super.constrainBoundsRect(proposedBounds)
      guard let documentView else { return rect }

      if rect.width > documentView.frame.width { rect.origin.x = (documentView.frame.width - rect.width) / 2 }
      if rect.height > documentView.frame.height { rect.origin.y = (documentView.frame.height - rect.height) / 2 }
      return rect
    }
  }
#else
  import UIKit

  struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView { ZoomableImageScrollView() }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) { view.show(image) }
  }

  @MainActor
  final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedSize = CGSize.zero

    private static let maximumZoom: CGFloat = 8
    private static let zoomedInScale: CGFloat = 2.5

    override init(frame: CGRect) {
      super.init(frame: frame)
      delegate = self
      showsVerticalScrollIndicator = false
      showsHorizontalScrollIndicator = false
      contentInsetAdjustmentBehavior = .never
      decelerationRate = .fast
      addSubview(imageView)
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
      doubleTap.numberOfTapsRequired = 2
      addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: UIImage) {
      guard imageView.image !== image else { return }

      imageView.image = image
      imageView.frame = CGRect(origin: .zero, size: image.size)
      contentSize = image.size
      fittedSize = .zero
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard fittedSize != bounds.size, bounds.width > 0, bounds.height > 0 else { return centerImage() }

      let wasFitted = fittedSize == .zero || zoomScale <= minimumZoomScale
      fittedSize = bounds.size
      minimumZoomScale = fitScale
      maximumZoomScale = max(Self.maximumZoom, fitScale)
      if wasFitted || zoomScale < fitScale { zoomScale = fitScale }
      centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private var fitScale: CGFloat {
      guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return 1 }
      return min(bounds.width / size.width, bounds.height / size.height)
    }

    private func centerImage() {
      let horizontal = max(0, (bounds.width - contentSize.width) / 2)
      let vertical = max(0, (bounds.height - contentSize.height) / 2)
      contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
      guard zoomScale <= minimumZoomScale else { return setZoomScale(minimumZoomScale, animated: true) }

      let scale = min(maximumZoomScale, minimumZoomScale * Self.zoomedInScale)
      let center = gesture.location(in: imageView)
      let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
      zoom(
        to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
        animated: true)
    }
  }
#endif
