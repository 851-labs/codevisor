import SwiftUI

public struct SidebarRowStatusSymbol: View {
  let status: SidebarRowStatus
  let size: CGFloat
  let color: Color?

  public init(status: SidebarRowStatus, size: CGFloat, color: Color? = nil) {
    self.status = status
    self.size = size
    self.color = color
  }

  public var body: some View {
    Image(systemName: status.systemImage)
      .font(.system(size: size))
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(color ?? status.color)
      .accessibilityLabel(status.title)
  }
}
