import SwiftUI

public struct SidebarRowStatusLabel: View {
  let status: SidebarRowStatus

  public init(status: SidebarRowStatus) {
    self.status = status
  }

  public var body: some View {
    HStack(spacing: 3) {
      Image(systemName: status.systemImage)
        .imageScale(.small)
      Text(status.title)
      if let since = status.workingSince {
        SidebarElapsedText(since: since)
      }
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(color)
    .lineLimit(1)
    .fixedSize()
  }

  private var color: Color {
    switch status.tone {
    case .attention: .orange
    case .active: .blue
    case .quiet: .secondary
    case .failure: .red
    }
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
