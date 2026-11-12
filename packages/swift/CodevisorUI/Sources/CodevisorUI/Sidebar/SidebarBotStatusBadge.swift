import SwiftUI

public struct SidebarBotStatusBadge: View {
  let status: SidebarRowStatus
  let showsLabel: Bool

  public init(status: SidebarRowStatus, showsLabel: Bool) {
    self.status = status
    self.showsLabel = showsLabel
  }

  public static func isVisible(_ status: SidebarRowStatus, showsLabel: Bool) -> Bool {
    showsLabel || !status.isAnimated
  }

  public var body: some View {
    SidebarRowStatusLabel(status: status, showsIcon: !status.isAnimated, showsText: showsLabel)
  }
}
