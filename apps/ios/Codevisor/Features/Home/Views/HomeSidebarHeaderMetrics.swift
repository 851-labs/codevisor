import SwiftUI
import UIKit

struct HomeSidebarHeaderMetrics {
  static let height: CGFloat = 40
  static let verticalInset: CGFloat = 9

  let isConversation: Bool
  var isFirst = false

  var gap: CGFloat {
    if isFirst { return 0 }
    return isConversation ? 22 : 18
  }

  var contentHeight: CGFloat { Self.height - 2 * Self.verticalInset }

  var horizontalInset: CGFloat { isConversation ? 16 : 20 }

  var insets: EdgeInsets {
    EdgeInsets(
      top: gap + Self.verticalInset, leading: horizontalInset, bottom: Self.verticalInset,
      trailing: horizontalInset)
  }

  var listBackground: UIColor { Self.listBackground(isConversation: isConversation) }

  static func listBackground(isConversation: Bool) -> UIColor {
    isConversation ? .systemBackground : .systemGroupedBackground
  }
}
