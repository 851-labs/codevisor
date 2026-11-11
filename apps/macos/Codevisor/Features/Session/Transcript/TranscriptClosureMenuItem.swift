import AppKit

nonisolated final class TranscriptClosureMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void

  @MainActor
  init(_ title: String, systemImage: String, handler: @escaping @MainActor () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
    target = self
    image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
  }

  @available(*, unavailable)
  required init(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor @objc private func runHandler() {
    handler()
  }
}
