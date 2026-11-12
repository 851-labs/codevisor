import SwiftUI

public struct SidebarRowStatusLabel: View {
  let status: SidebarRowStatus
  let showsIcon: Bool
  let showsText: Bool

  public init(status: SidebarRowStatus, showsIcon: Bool = true, showsText: Bool = true) {
    self.status = status
    self.showsIcon = showsIcon
    self.showsText = showsText
  }

  public var body: some View {
    HStack(spacing: 3) {
      if showsIcon {
        Image(systemName: status.systemImage)
          .imageScale(.small)
      }
      if showsText {
        Text(status.title)
        if let since = status.workingSince {
          SidebarElapsedText(since: since)
        }
      }
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(status.color)
    .lineLimit(1)
    .fixedSize()
  }
}

private struct SidebarElapsedText: View {
  let since: Date
  private let clock = SidebarElapsedClock.shared

  var body: some View {
    Text(SidebarRowStatus.elapsed(from: since, to: clock.now))
      .monospacedDigit()
      .onAppear { clock.watch() }
      .onDisappear { clock.unwatch() }
  }
}
