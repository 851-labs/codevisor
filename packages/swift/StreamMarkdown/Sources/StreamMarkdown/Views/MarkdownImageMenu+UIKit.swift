#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  /// The menu for an inline image: the host's preview, a new-tab open, and
  /// a copy of the original bytes. Text links keep the system menu.
  @MainActor
  func markdownImageMenuConfiguration(
    in textView: UITextView, for textItem: UITextItem, defaultMenu: UIMenu, action: MarkdownLinkAction?
  ) -> UITextItem.MenuConfiguration? {
    guard case let .link(url) = textItem.content,
      let images = action?.images,
      textView.textStorage.streamMarkdownHasImage(at: textItem.range.location)
    else { return .init(menu: defaultMenu) }
    var actions: [UIAction] = [
      UIAction(title: "Quick Look", image: UIImage(systemName: "eye")) { _ in _ = images.open(url) }
    ]
    if let openInNewTab = images.openInNewTab {
      actions.append(
        UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { _ in
          openInNewTab(url)
        })
    }
    if let copy = images.copy {
      actions.append(UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in copy(url) })
    }
    return .init(menu: UIMenu(children: actions))
  }
#endif
