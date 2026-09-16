#if canImport(AppKit)
  import AppKit

  extension TranscriptSurfaceTextView {
    /// The menu for a secondary click on an inline image: the host's
    /// preview, a new-tab open, and a copy of the original bytes. Nil off
    /// an image, so text and links keep their usual menus.
    func markdownImageMenu(at point: NSPoint) -> NSMenu? {
      guard let images = linkAction?.images, let textStorage, textStorage.length > 0 else { return nil }
      let index = characterIndexForInsertion(at: point)
      guard index != NSNotFound else { return nil }
      for candidate in [index, index - 1] where candidate >= 0 && candidate < textStorage.length {
        guard textStorage.streamMarkdownHasImage(at: candidate) else { continue }
        let attributes = textStorage.attributes(at: candidate, effectiveRange: nil)
        guard let link = attributes[.link] ?? attributes[.streamMarkdownServerFileLink],
          let url = markdownLinkURL(link)
        else { continue }
        let menu = NSMenu()
        menu.addItem(MarkdownMenuItem("Quick Look", systemImage: "eye") { _ = images.open(url) })
        if let openInNewTab = images.openInNewTab {
          menu.addItem(
            MarkdownMenuItem("Open in New Tab", systemImage: "plus.rectangle.on.rectangle") { openInNewTab(url) })
        }
        if let copy = images.copy {
          menu.addItem(MarkdownMenuItem("Copy Image", systemImage: "doc.on.doc") { copy(url) })
        }
        return menu
      }
      return nil
    }
  }

  /// A menu item that runs a closure; `NSMenuItem.target` is weak, so the
  /// item can be its own target without a retain cycle.
  @MainActor
  private final class MarkdownMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, systemImage: String, handler: @escaping @MainActor () -> Void) {
      self.handler = handler
      super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
      target = self
      image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runHandler() { handler() }
  }
#endif
