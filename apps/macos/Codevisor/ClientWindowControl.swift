import AppKit
import CodevisorCore
import SwiftUI

/// Bound to the root's actual host, never NSApp.keyWindow (which may belong
/// to another client). Screen coordinates use AppKit points.
@MainActor
final class ClientWindowControl {
  weak var window: NSWindow?

  func context(sidebarVisible: Bool) -> ClientWindowContext? {
    guard let window else { return nil }
    return ClientWindowContext(
      frame: window.frame, isMinimized: window.isMiniaturized,
      isFullscreen: window.styleMask.contains(.fullScreen), sidebarVisible: sidebarVisible
    )
  }

  func perform(_ request: ClientWindowRequest) async throws {
    guard let window else { throw ClientControlError("Window is unavailable") }
    switch request.action {
    case "focus":
      try await restore(window)
      if !window.isKeyWindow {
        try await acknowledgeWindowChange(window: window, notification: NSWindow.didBecomeKeyNotification) {
          NSApp.activate(ignoringOtherApps: true)
          window.makeKeyAndOrderFront(nil)
        }
      }
    case "minimize":
      if !window.isMiniaturized {
        guard !window.styleMask.contains(.fullScreen) else {
          throw ClientControlError("Exit fullscreen before minimizing")
        }
        try await acknowledgeWindowChange(window: window, notification: NSWindow.didMiniaturizeNotification) {
          window.miniaturize(nil)
        }
      }
    case "restore": try await restore(window)
    case "frame":
      guard !window.styleMask.contains(.fullScreen) else {
        throw ClientControlError("Exit fullscreen before changing the window frame")
      }
      guard let x = request.x, let y = request.y, let width = request.width, let height = request.height,
        [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
      else { throw ClientControlError("A finite frame with positive dimensions is required") }
      let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
      let frame = CGRect(
        x: x, y: y, width: max(width, minimum.width, window.minSize.width),
        height: max(height, minimum.height, window.minSize.height))
      guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) else {
        throw ClientControlError("Window frame must fit within a screen's visible bounds")
      }
      window.setFrame(frame, display: true)
    case "fullscreen":
      guard let enabled = request.enabled else { throw ClientControlError("Missing fullscreen state") }
      guard window.styleMask.contains(.fullScreen) != enabled else { return }
      let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
      try await acknowledgeWindowChange(window: window, notification: name) {
        window.toggleFullScreen(nil)
      }
    default: throw ClientControlError("Window action is unsupported")
    }
  }

  private func restore(_ window: NSWindow) async throws {
    if window.isMiniaturized {
      try await acknowledgeWindowChange(window: window, notification: NSWindow.didDeminiaturizeNotification) {
        window.deminiaturize(nil)
      }
    }
  }
}

/// Subscribe before the action, with a bounded wait. Cancellation removes
/// observers so a closed client never retains its window or a pending command.
@MainActor
func acknowledgeWindowChange(
  window: NSWindow?, notification: Notification.Name,
  matches: @escaping @MainActor (NSWindow) -> Bool = { _ in true }, action: () -> Void
) async throws {
  let stream = AsyncStream<Void> { continuation in
    let observer = NotificationCenter.default.addObserver(forName: notification, object: window, queue: .main) {
      event in
      guard let changed = event.object as? NSWindow, MainActor.assumeIsolated({ matches(changed) }) else { return }
      continuation.yield(())
      continuation.finish()
    }
    continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
  }
  action()
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      for await _ in stream { return }; try Task.checkCancellation()
    }
    group.addTask {
      try await Task.sleep(for: .seconds(8))
      throw ClientControlError("Window did not finish the transition. Read context before retrying.")
    }
    defer { group.cancelAll() }
    _ = try await group.next()
  }
}

struct ClientWindowReader: NSViewRepresentable {
  let control: ClientWindowControl
  func makeNSView(context: Context) -> Probe { Probe(control: control) }
  func updateNSView(_ nsView: Probe, context: Context) {}

  final class Probe: NSView {
    let control: ClientWindowControl
    init(control: ClientWindowControl) { self.control = control; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // SwiftUI may attach a replacement probe before detaching the old
      // one. The outgoing probe must not clear the new host reference.
      if let window { control.window = window }
    }
  }
}
