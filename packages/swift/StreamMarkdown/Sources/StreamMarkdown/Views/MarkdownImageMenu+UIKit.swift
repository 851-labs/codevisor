#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  func markdownImageMenuConfiguration(
    in textView: UITextView, for textItem: UITextItem, defaultMenu: UIMenu, action: MarkdownLinkAction?
  ) -> UITextItem.MenuConfiguration? {
    guard case let .link(url) = textItem.content,
      let images = action?.images,
      textView.textStorage.streamMarkdownHasImage(at: textItem.range.location)
    else { return .init(menu: defaultMenu) }
    var actions: [UIAction] = [
      UIAction(title: "Quick Look", image: UIImage(systemName: "eye")) { [weak textView] _ in
        guard let preparing = images.open(url), let textView else { return }
        MarkdownImageLoadingIndicator.track(preparing, in: textView, characterIndex: textItem.range.location)
      }
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
