import AppKit
import SwiftUI

/// What every navigator list shares: Xcode's density (22pt rows of 13pt text
/// and 16pt icons) on the inspector's own backdrop. The small sidebar row
/// size still spaces rows 24pt apart; going tighter needs an outline view.
enum NavigatorList {
  static let rowHeight: CGFloat = 22
  static let indent: CGFloat = 14
  static let iconSize: CGFloat = 16

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension View {
  /// A row at the navigator's height: the sidebar style's own vertical
  /// padding would make each row 8pt taller than Xcode's.
  func navigatorRow() -> some View {
    listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
  }

  func navigatorListStyle() -> some View {
    listStyle(.sidebar)
      .environment(\.sidebarRowSize, .small)
      .environment(\.defaultMinListRowHeight, NavigatorList.rowHeight)
      .scrollContentBackground(.hidden)
  }
}
