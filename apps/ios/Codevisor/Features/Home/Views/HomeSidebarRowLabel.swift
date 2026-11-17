import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarRowLabel: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let details: HomeSidebarRowDetails

  var body: some View {
    HStack(spacing: 10) {
      label
      trailingDetails
    }
    .contentShape(Rectangle())
  }

  private var label: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        HomeSidebarRowTitle(title: details.title)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        if details.subtitle != nil || details.statusLabel != nil {
          SidebarRowStatusSubtitle(status: details.statusLabel, subtitle: details.subtitle) { text in
            HomeSidebarRowSubtitle(text: text)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } icon: {
      leadingIcon
    }
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if let status = details.leadingStatus {
      HomeSidebarStatusSymbol(status: status)
    } else if let row = details.leadingRow {
      HomeSidebarTabIcon(row: row, serverId: details.serverId)
    } else {
      HomeSidebarSymbol(name: EntitySystemSymbol.workspace)
    }
  }

  @ViewBuilder
  private var trailingDetails: some View {
    if let pullRequest = details.pullRequest {
      PullRequestBadge(pullRequest: pullRequest, size: 15, slot: 22)
    }
    if let machine = details.machine {
      HomeSidebarSymbol(name: machine.systemImage)
        .imageScale(.small)
    }
    if !details.isArchived {
      Image(systemName: "chevron.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
  }
}

private struct HomeSidebarRowSubtitle: View {
  let text: String
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Text(text)
      .font(.caption)
      .lineLimit(1)
      .foregroundStyle(
        backgroundProminence == .increased ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
  }
}
