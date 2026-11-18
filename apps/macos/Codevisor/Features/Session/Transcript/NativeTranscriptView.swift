import AppKit
import CodevisorCore
import QuartzCore
import StreamMarkdown
import SwiftUI
import CodevisorUI

struct NativeTranscriptView: NSViewRepresentable {
  let presentationSurface: TranscriptPresentationSurface
  let input: TranscriptSurfaceInput
  let callbacks: TranscriptSurfaceCallbacks
  let markdownRowStyle: TranscriptMarkdownRowStyle
  var topChromeHeight: CGFloat = 0
  var addToChatShortcut: TranscriptAddToChatShortcut?
  var keepsSurfacesAside = false
  var onInitialPresentationReady: (@MainActor () -> Void)? = nil
  var onScrollViewReady: (@MainActor (NSView) -> Void)? = nil

  final class SurfaceContainerView: NSView {
    var presentationSurface: TranscriptPresentationSurface?
    var reclaimSurface: (() -> Void)?
    var keepsSurfacesAside = false

    override func layout() {
      super.layout()
      reclaimSurface?()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        reclaimSurface?()
      }
    }

    func releaseSurface() {
      if let presentationSurface, let scrollView = presentationSurface.existingScrollView,
        scrollView.superview === self
      {
        scrollView.prepareForDismantle()
        scrollView.removeFromSuperview()
        if !presentationSurface.isWarm { presentationSurface.presentation.forgetMount() }
      }
      presentationSurface = nil
      reclaimSurface = nil
      for case let aside as VirtualizedTranscriptScrollView in subviews {
        aside.prepareForDismantle()
        aside.removeFromSuperview()
      }
    }

    func setSurfaceAside() {
      if let scrollView = presentationSurface?.existingScrollView, scrollView.superview === self {
        scrollView.setAside()
      }
      presentationSurface = nil
      reclaimSurface = nil
    }

    func relinquishSurface(_ surface: TranscriptPresentationSurface) {
      guard presentationSurface === surface else { return }
      presentationSurface = nil
      reclaimSurface = nil
    }
  }

  func makeNSView(context: Context) -> SurfaceContainerView {
    let container = SurfaceContainerView()
    container.keepsSurfacesAside = keepsSurfacesAside
    let scrollView = presentationSurface.ensureScrollView()
    container.presentationSurface = presentationSurface
    container.reclaimSurface = { [weak container] in
      guard let container else { return }
      Self.attach(presentationSurface, to: container)
    }
    scrollView.prepareForPresentationAttachment()
    Self.attach(presentationSurface, to: container)
    configure(scrollView)
    onScrollViewReady?(scrollView)
    return container
  }

  func updateNSView(_ container: SurfaceContainerView, context: Context) {
    container.keepsSurfacesAside = keepsSurfacesAside
    if container.presentationSurface !== presentationSurface {
      showSurface(in: container)
    }
    container.reclaimSurface = { [weak container] in
      guard let container else { return }
      Self.attach(presentationSurface, to: container)
    }
    Self.attach(presentationSurface, to: container)
    configure(presentationSurface.ensureScrollView())
  }

  private func showSurface(in container: SurfaceContainerView) {
    if keepsSurfacesAside {
      container.setSurfaceAside()
    } else {
      container.releaseSurface()
    }
    container.presentationSurface = presentationSurface
    let scrollView = presentationSurface.ensureScrollView()
    if scrollView.superview === container {
      scrollView.showFromAside()
    } else {
      scrollView.prepareForPresentationAttachment()
    }
    onScrollViewReady?(scrollView)
  }

  static func dismantleNSView(_ container: SurfaceContainerView, coordinator: Void) {
    container.releaseSurface()
  }

  private func configure(_ view: VirtualizedTranscriptScrollView) {
    view.onInitialPresentationReady = reportInitialPresentationReady
    view.markdownRowStyle = markdownRowStyle
    view.topChromeHeight = topChromeHeight
    view.addToChatShortcut = addToChatShortcut
    view.configureWhenOnScreen(input, callbacks: callbacks)
    if view.isInitialPresentationReady {
      reportInitialPresentationReady()
    }
  }

  @MainActor
  private static func attach(
    _ presentationSurface: TranscriptPresentationSurface,
    to container: SurfaceContainerView
  ) {
    let scrollView = presentationSurface.ensureScrollView()
    guard scrollView.superview !== container else { return }
    guard container.window != nil else { return }

    (scrollView.superview as? SurfaceContainerView)?
      .relinquishSurface(presentationSurface)
    scrollView.removeFromSuperview()
    if container.keepsSurfacesAside {
      for case let aside as VirtualizedTranscriptScrollView in container.subviews { aside.setAside() }
    } else {
      container.subviews.forEach { $0.removeFromSuperview() }
    }
    scrollView.isHidden = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }

  private func reportInitialPresentationReady() {
    guard let onInitialPresentationReady else { return }
    DispatchQueue.main.async {
      onInitialPresentationReady()
    }
  }
}
