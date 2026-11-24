#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  func markdownFileMenuConfiguration(
    for textItem: UITextItem, defaultMenu: UIMenu, action: MarkdownLinkAction?
  ) -> UITextItem.MenuConfiguration? {
    guard case let .link(url) = textItem.content, let items = action?.files?.menu(url), !items.isEmpty
    else { return .init(menu: defaultMenu) }
    return .init(menu: UIMenu(children: markdownMenuSections(items)))
  }

  @MainActor
  private func markdownMenuSections(_ items: [MarkdownLinkMenuItem]) -> [UIMenu] {
    var sections: [[UIAction]] = [[]]
    for item in items {
      switch item {
      case let .action(title, systemImage, perform):
        sections[sections.count - 1].append(
          UIAction(title: title, image: UIImage(systemName: systemImage)) { _ in perform() })
      case .separator:
        sections.append([])
      }
    }
    return sections.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
  }
#endif
