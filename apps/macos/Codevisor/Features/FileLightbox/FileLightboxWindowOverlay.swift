import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct FileLightboxWindowOverlay: View {
  let lightbox: FileLightbox
  let environment: AppEnvironment

  var body: some View {
    FileLightboxWindowAnchor(isPresented: lightbox.isPresented, lightbox: lightbox, environment: environment)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
  }
}

private struct FileLightboxWindowAnchor: NSViewRepresentable {
  let isPresented: Bool
  let lightbox: FileLightbox
  let environment: AppEnvironment

  func makeCoordinator() -> FileLightboxWindowPresenter { FileLightboxWindowPresenter() }

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    guard isPresented else { return context.coordinator.remove() }

    context.coordinator.present(in: view.window) {
      FileLightboxOverlayView(lightbox: lightbox, environment: environment)
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: FileLightboxWindowPresenter) {
    coordinator.remove()
  }
}

final class FileLightboxWindowPresenter {
  private var overlay: FileLightboxOverlayView?
  private var focusReturn: WindowFocusReturn?
  private var keyMonitor: Any?

  private static let fadeIn: TimeInterval = 0.14

  func present(in window: NSWindow?, makeOverlay: () -> FileLightboxOverlayView) {
    guard overlay == nil, let window, let frame = window.contentView?.superview else { return }

    let overlay = makeOverlay()
    overlay.frame = frame.bounds
    overlay.autoresizingMask = [.width, .height]
    overlay.alphaValue = 0
    focusReturn = WindowFocusReturn(window: window)
    frame.addSubview(overlay, positioned: .above, relativeTo: nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeIn
      overlay.animator().alphaValue = 1
    }
    self.overlay = overlay
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.overlay?.consume(event) == true ? nil : event
    }
  }

  func remove() {
    guard let overlay else { return }

    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    overlay.removeFromSuperview()
    self.overlay = nil
    focusReturn?.restore()
    focusReturn = nil
  }
}

final class FileLightboxOverlayView: NSView {
  private let lightbox: FileLightbox

  private enum Key {
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
  }

  init(lightbox: FileLightbox, environment: AppEnvironment) {
    self.lightbox = lightbox
    super.init(frame: .zero)
    let host = NSHostingView(rootView: FileLightboxPanel(lightbox: lightbox).themedRoot().environment(environment))
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func consume(_ event: NSEvent) -> Bool {
    guard event.window === window else { return false }
    if event.keyCode == Key.escape || isClose(event) {
      lightbox.dismiss()
      return true
    }
    if holdsFocus || isCommand(event) { return false }

    page(for: event)
    return true
  }

  override func mouseDown(with event: NSEvent) {}

  override func scrollWheel(with event: NSEvent) {}

  private var holdsFocus: Bool {
    (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
  }

  private func page(for event: NSEvent) {
    switch event.keyCode {
    case Key.leftArrow: lightbox.showPrevious()
    case Key.rightArrow: lightbox.showNext()
    default: break
    }
  }

  private func isCommand(_ event: NSEvent) -> Bool {
    event.modifierFlags.contains(.command)
  }

  private func isClose(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
      && event.charactersIgnoringModifiers == "w"
  }
}
