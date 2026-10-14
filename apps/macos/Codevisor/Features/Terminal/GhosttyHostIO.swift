import AppKit
import CodevisorCore
import Foundation
import GhosttyKit

final class GhosttyHostIO: @unchecked Sendable {
  nonisolated(unsafe) private weak var controller: TerminalController?

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
      MainActor.assumeIsolated { bridge.controller?.start(cols: Int(cols), rows: Int(rows)) }
    }
  }
}

@MainActor
final class GhosttySurfaceRenderer: TerminalRenderer {
  private let target: SurfaceTarget
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
    target.enqueue(bytes) { surface, chunk in
      ghostty_surface_write_buffer(surface, chunk.baseAddress, UInt(chunk.count))
    }
  }

  func writeReplay(_ bytes: [UInt8]) {
    target.enqueue(bytes) { surface, chunk in
      ghostty_surface_write_buffer_replay(surface, chunk.baseAddress, UInt(chunk.count))
    }
  }

  func processExited(code: Int?) {
    let runtime = TerminalTransport.milliseconds(attachedAt.duration(to: .now))
    target.enqueue { surface in
      ghostty_surface_process_exit(
        surface, UInt32(truncatingIfNeeded: code ?? 0), UInt64(max(0, runtime)))
    }
  }

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
    ghostty_surface_ime_point(surface, &x, &y, &width, &cellHeight)
    let cellWidth = Double(ghostty_surface_size(surface).cell_width_px) / (view.window?.backingScaleFactor ?? 2)
    guard cellWidth > 0, cellHeight > 0 else { return }
    x -= cellWidth / 2
    let label = predictionLabel ?? Self.makePredictionLabel()
    if label.superview !== view { view.addSubview(label) }
    predictionLabel = label
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

  func retire(then released: @escaping @MainActor @Sendable () -> Void) {
    target.retire(then: released)
  }
}

nonisolated private final class SurfaceTarget: @unchecked Sendable {
  static let chunkSize = 64 * 1024

  private let lock = NSLock()
  private var surface: ghostty_surface_t?
  private let queue = DispatchQueue(label: "dev.codevisor.terminal.surface-output", qos: .userInteractive)

  init(surface: ghostty_surface_t?) {
    self.surface = surface
  }

  func enqueue(
    _ bytes: [UInt8],
    write: @escaping @Sendable (ghostty_surface_t, UnsafeBufferPointer<UInt8>) -> Void
  ) {
    var start = bytes.startIndex
    while start < bytes.endIndex {
      let range = start..<min(bytes.endIndex, start + Self.chunkSize)
      enqueue { surface in
        bytes.withUnsafeBufferPointer { buffer in write(surface, UnsafeBufferPointer(rebasing: buffer[range])) }
      }
      start = range.upperBound
    }
  }

  func enqueue(_ write: @escaping @Sendable (ghostty_surface_t) -> Void) {
    queue.async { [self] in
      guard let surface = lock.withLock({ surface }) else { return }
      write(surface)
    }
  }

  func retire(then released: @escaping @MainActor @Sendable () -> Void) {
    lock.withLock { surface = nil }
    queue.async {
      Task { @MainActor in released() }
    }
  }
}
