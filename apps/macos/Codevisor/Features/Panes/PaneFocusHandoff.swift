import AppKit

@MainActor
final class PaneFocusHandoff {
  private static let timeout: Duration = .seconds(1)

  private weak var window: NSWindow?
  private var monitor: Any?
  private var observation: NSKeyValueObservation?
  private var timeoutTask: Task<Void, Never>?
  private var buffered: [NSEvent] = []
  private var isReady: (NSResponder?) -> Bool = { _ in true }

  func begin(in window: NSWindow?, until isReady: @escaping (NSResponder?) -> Bool) {
    finish()
    guard let window else { return }

    self.window = window
    self.isReady = isReady
    window.makeFirstResponder(nil)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isForWindow(event), !event.modifierFlags.contains(.command) else { return event }
      self.buffered.append(event)
      return nil
    }
    observation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
      MainActor.assumeIsolated {
        guard let self, self.isReady(window.firstResponder) else { return }
        Task { @MainActor [weak self] in self?.finish() }
      }
    }
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: Self.timeout)
      guard !Task.isCancelled else { return }
      self?.finish()
    }
  }

  private func isForWindow(_ event: NSEvent) -> Bool {
    guard let window else { return false }
    return event.window === window || (event.window == nil && NSApp.keyWindow === window)
  }

  private func finish() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    observation = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    let events = buffered
    buffered = []
    events.forEach { window?.firstResponder?.keyDown(with: $0) }
  }
}
