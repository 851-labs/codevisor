import ApplicationServices

enum MenuMarks {
  private static let markAttribute = "AXMenuItemMarkChar"

  static func checked(in application: AccessibilityElement) -> [String] {
    entries(in: application).compactMap { checkedTitle($0.entry, menu: $0.menu) }
  }

  static func entries(in application: AccessibilityElement) -> [(menu: String, entry: AccessibilityElement)] {
    guard let bar = application.element(kAXMenuBarAttribute) else { return [] }

    return bar.children().flatMap { item in
      let menu = item.string(kAXTitleAttribute) ?? ""
      return item.children().flatMap { $0.children() }.map { (menu: menu, entry: $0) }
    }
  }

  private static func checkedTitle(_ entry: AccessibilityElement, menu: String) -> String? {
    guard let mark = entry.string(markAttribute), !mark.isEmpty, let title = entry.string(kAXTitleAttribute) else {
      return nil
    }

    return "\(menu) › \(title)"
  }
}
