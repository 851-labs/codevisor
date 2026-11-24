#if canImport(AppKit)
  import AppKit
  import DefaultBrowser

  extension TranscriptSurfaceTextView {
    func markdownFileMenu(at point: NSPoint) -> NSMenu? {
      guard let files = linkAction?.files, let url = linkURL(at: point) else { return nil }
      let items = files.menu(url)
      guard !items.isEmpty else { return nil }

      return MarkdownLinkMenu.menu(for: items)
    }

    private func linkURL(at point: NSPoint) -> URL? {
      guard let textStorage, textStorage.length > 0 else { return nil }
      let index = characterIndexForInsertion(at: point)
      guard index != NSNotFound else { return nil }
      for candidate in [index, index - 1] where candidate >= 0 && candidate < textStorage.length {
        let attributes = textStorage.attributes(at: candidate, effectiveRange: nil)
        guard let link = attributes[.link] ?? attributes[.streamMarkdownServerFileLink],
          let url = markdownLinkURL(link)
        else { continue }
        return url
      }
      return nil
    }

    func markdownWebLinkMenu(at point: NSPoint) -> NSMenu? {
      guard let url = markdownWebLinkURL(at: point) else { return nil }
      let menu = NSMenu()
      if let webLinks = linkAction?.webLinks {
        let open: @MainActor (MarkdownWebLinkActions.Destination) -> Void = { destination in
          if !webLinks.open(url, destination) { DefaultBrowser.open(url) }
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
      ) { DefaultBrowser.open(url) }
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
      guard let url = linkURL(at: point), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { return nil }
      return url
    }
  }
#endif
