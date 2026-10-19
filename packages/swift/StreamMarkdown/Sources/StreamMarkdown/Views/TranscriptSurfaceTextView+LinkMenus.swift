#if canImport(AppKit)
  import AppKit

  extension TranscriptSurfaceTextView {
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
        menu.addItem(
          MarkdownMenuItem("Quick Look", systemImage: "eye") { [weak self] in
            guard let preparing = images.open(url), let self else { return }
            MarkdownImageLoadingIndicator.track(preparing, in: self, characterIndex: candidate)
          })
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

    func markdownWebLinkMenu(at point: NSPoint) -> NSMenu? {
      guard let url = markdownWebLinkURL(at: point) else { return nil }
      let menu = NSMenu()
      if let webLinks = linkAction?.webLinks {
        let open: @MainActor (MarkdownWebLinkActions.Destination) -> Void = { destination in
          if !webLinks.open(url, destination) { NSWorkspace.shared.open(url) }
        }
        menu.addItem(MarkdownMenuItem("Open Link in New Tab", systemImage: "plus.square.on.square") { open(.newTab) })
        menu.addItem(
          MarkdownMenuItem("Open Link in New Window", systemImage: "macwindow.badge.plus") { open(.newWindow) })
        menu.addItem(MarkdownMenuItem("Open Link in Split", systemImage: "rectangle.split.2x1") { open(.split) })
        menu.addItem(.separator())
      }
      let browser = NSWorkspace.shared.urlForApplication(toOpen: url)
      let browserItem = MarkdownMenuItem(
        browser.map { "Open Link in \($0.deletingPathExtension().lastPathComponent)" }
          ?? "Open Link in Default Browser",
        systemImage: "safari"
      ) { NSWorkspace.shared.open(url) }
      if let browser {
        let icon = NSWorkspace.shared.icon(forFile: browser.path)
        icon.size = NSSize(width: 16, height: 16)
        browserItem.image = icon
      }
      menu.addItem(browserItem)
      menu.addItem(.separator())
      menu.addItem(
        MarkdownMenuItem("Copy Link Address", systemImage: "link") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
      return menu
    }

    private func markdownWebLinkURL(at point: NSPoint) -> URL? {
      guard let textStorage, textStorage.length > 0 else { return nil }
      let index = characterIndexForInsertion(at: point)
      guard index != NSNotFound else { return nil }
      for candidate in [index, index - 1] where candidate >= 0 && candidate < textStorage.length {
        guard let link = textStorage.attribute(.link, at: candidate, effectiveRange: nil),
          let url = markdownLinkURL(link),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { continue }
        return url
      }
      return nil
    }
  }

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
