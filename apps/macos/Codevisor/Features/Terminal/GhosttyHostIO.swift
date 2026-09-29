import AppKit
import CodevisorCore
import Foundation
import GhosttyKit

/// Connects a libghostty surface in host-managed I/O mode to a
/// `TerminalController`: no local process runs behind the surface. The
/// server's PTY output is written into the surface, and what the surface
/// produces (keystrokes, paste, query replies, size changes) goes back to
/// the server.
///
/// libghostty calls `receiveBuffer`/`receiveResize` on its I/O thread; they
/// hop to the main queue, which keeps their order, before touching the
/// controller.
final class GhosttyHostIO: @unchecked Sendable {
  /// Only read and written on the main actor.
  nonisolated(unsafe) private weak var controller: TerminalController?

  /// libghostty keeps the userdata pointer until it frees the C surface,
  /// which happens asynchronously after the view is released. The bridge is
  /// therefore retained for the life of the process (it holds nothing but a
  /// weak reference), so a callback that races surface teardown never
  /// reaches freed memory.
  static func make(for controller: TerminalController) -> GhosttyHostIO {
    let bridge = GhosttyHostIO()
    bridge.controller = controller
    _ = Unmanaged.passRetained(bridge)
    return bridge
  }

  var surfaceIO: Ghostty.SurfaceConfiguration.HostIO {
    .init(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      receiveBuffer: Self.receiveBuffer,
      receiveResize: Self.receiveResize)
  }

  private static let receiveBuffer: ghostty_surface_receive_buffer_cb = { userdata, pointer, count in
    guard let userdata, let pointer, count > 0 else { return }
    let bridge = Unmanaged<GhosttyHostIO>.fromOpaque(userdata).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: pointer, count: count))
    DispatchQueue.main.async {
      MainActor.assumeIsolated { bridge.controller?.produced(bytes) }
    }
  }

  private static let receiveResize: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
    guard let userdata else { return }
    let bridge = Unmanaged<GhosttyHostIO>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      // The first size the surface lays out at opens the server terminal.
      MainActor.assumeIsolated { bridge.controller?.start(cols: Int(cols), rows: Int(rows)) }
    }
  }
}

/// Feeds a surface the stream a `TerminalController` receives.
///
/// Writes run on a serial background queue, as libghostty-spm's own host
/// does: parsing can wait for the main thread to drain Ghostty's app
/// mailbox, so a write on the main thread stalls rendering until the next
/// input event. The queue keeps the controller's order.
@MainActor
final class GhosttySurfaceRenderer: TerminalRenderer {
  private let target: SurfaceTarget
  /// When the surface was attached to the server terminal. Ghostty reports
  /// an exit with (near) zero runtime as a failed launch, so the exit
  /// carries how long the terminal was shown.
  private let attachedAt = ContinuousClock.now
  private let surface: ghostty_surface_t?
  private weak var view: NSView?
  private var predictionLabel: NSTextField?

  init(surface: ghostty_surface_t?, view: NSView) {
    target = SurfaceTarget(surface: surface)
    self.surface = surface
    self.view = view
  }

  func writeLive(_ bytes: [UInt8]) {
    target.enqueue { surface in
      bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        ghostty_surface_write_buffer(surface, base, UInt(buffer.count))
      }
    }
  }

  func writeReplay(_ bytes: [UInt8]) {
    target.enqueue { surface in
      bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        ghostty_surface_write_buffer_replay(surface, base, UInt(buffer.count))
      }
    }
  }

  func processExited(code: Int?) {
    let runtime = TerminalTransport.milliseconds(attachedAt.duration(to: .now))
    target.enqueue { surface in
      ghostty_surface_process_exit(
        surface, UInt32(truncatingIfNeeded: code ?? 0), UInt64(max(0, runtime)))
    }
  }

  /// Local echo on slow links, drawn over the cursor cell in the surface's
  /// monospaced font metrics until the server's echo replaces it.
  func showPrediction(_ overlay: EchoPredictor.Overlay?) {
    guard let overlay, let surface, let view else {
      predictionLabel?.removeFromSuperview()
      predictionLabel = nil
      return
    }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var cellHeight = 0.0
    // The middle of the cursor cell's bottom edge; the width is only the
    // composing text's (preedit), so the cell's comes from the grid.
    ghostty_surface_ime_point(surface, &x, &y, &width, &cellHeight)
    let cellWidth = Double(ghostty_surface_size(surface).cell_width_px) / (view.window?.backingScaleFactor ?? 2)
    guard cellWidth > 0, cellHeight > 0 else { return }
    x -= cellWidth / 2
    let label = predictionLabel ?? Self.makePredictionLabel()
    if label.superview !== view { view.addSubview(label) }
    predictionLabel = label
    // JetBrains Mono (Ghostty's default) advances 0.6em per character.
    let font =
      NSFont(name: "JetBrainsMono-Regular", size: cellWidth / 0.6)
      ?? .monospacedSystemFont(ofSize: cellWidth / 0.6, weight: .regular)
    label.attributedStringValue = NSAttributedString(
      string: overlay.text,
      attributes: [
        .font: font,
        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
        .underlineStyle: overlay.underlined ? NSUnderlineStyle.single.rawValue : 0,
      ])
    // Ghostty reports the cursor from the top-left; AppKit lays out from the
    // bottom-left.
    label.frame = NSRect(
      x: x, y: view.bounds.height - y, width: cellWidth * Double(overlay.text.count) + 2,
      height: cellHeight)
  }

  private static func makePredictionLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.isBezeled = false
    label.drawsBackground = false
    label.isEditable = false
    label.isSelectable = false
    label.lineBreakMode = .byClipping
    return label
  }

  /// Stops all writes before the surface is freed. Waits for one in
  /// flight, ticking the app meanwhile so a write waiting on the main
  /// thread can finish.
  func invalidate() {
    target.invalidate()
  }
}

/// The C surface, guarded so no write can run once it is invalidated.
private final class SurfaceTarget: @unchecked Sendable {
  private let lock = NSLock()
  private var surface: ghostty_surface_t?
  private let queue = DispatchQueue(label: "dev.codevisor.terminal.surface-output", qos: .userInteractive)

  init(surface: ghostty_surface_t?) {
    self.surface = surface
  }

  func enqueue(_ write: @escaping @Sendable (ghostty_surface_t) -> Void) {
    queue.async { [self] in
      lock.lock()
      defer { lock.unlock() }
      guard let surface else { return }
      write(surface)
    }
  }

  func invalidate() {
    while !lock.try() {
      if let surface { ghostty_app_tick(ghostty_surface_app(surface)) }
      usleep(1000)
    }
    surface = nil
    lock.unlock()
  }
}
