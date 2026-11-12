import CodevisorUI
import SwiftUI

struct HomeSidebarStatusSymbol: View {
  let status: SidebarRowStatus
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 15
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    SidebarRowStatusSymbol(status: status, size: size, color: backgroundProminence == .increased ? .white : nil)
  }
}
