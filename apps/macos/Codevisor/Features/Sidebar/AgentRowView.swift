import CodevisorCore
import CodevisorUI
import SwiftUI

/// An agent's state as its row's leading mark: the working spinner, the
/// question ring, an unread or error dot, or nothing at rest.
struct AgentStatusMark: View {
  let status: AgentStatus

  var body: some View {
    Group {
      switch status {
      case .working: AgentActivityIndicator()
      case .waiting: ActionRequiredIndicator(color: .accentColor)
      case .errored: ErrorUnreadBadge(color: .red)
      case .unread: UnreadBadge(color: .accentColor)
      case .idle: Image(systemName: "bubble.left").foregroundStyle(.secondary).imageScale(.small)
      }
    }
    .frame(width: 16, height: 16)
  }
}

/// A top-level agent: its status, name, where it runs, and how its
/// subagents are doing. The chevron shows them.
struct AgentRowView: View {
  let row: AgentSidebarRow
  /// "branch · machine", or nil when there is nothing worth saying.
  let detail: String?
  let isSelected: Bool
  let isExpanded: Bool
  let showsSubagents: Bool
  let onActivate: () -> Void
  let onToggle: () -> Void

  var body: some View {
    HoverableRow(isSelected: isSelected) { _ in
      HStack(spacing: 7) {
        AgentStatusMark(status: row.status)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.title).lineLimit(1)
          if let detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if showsSubagents, let rollup = row.rollup {
          rollupView(rollup)
        }
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
      .onTapGesture(perform: onActivate)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { onActivate() }
  }

  /// "2/5" with the chevron that shows the subagents; a blocked subagent
  /// tints it so the user sees it without expanding.
  private func rollupView(_ rollup: AgentRollup) -> some View {
    Button(action: onToggle) {
      HStack(spacing: 3) {
        if rollup.status.isBlocked {
          Circle().fill(Color.orange).frame(width: 6, height: 6)
        }
        Text("\(rollup.finished)/\(rollup.total)").monospacedDigit()
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isExpanded ? "Hide Subagents" : "Show Subagents")
    .accessibilityLabel("\(rollup.finished) of \(rollup.total) subagents finished")
  }
}

/// One of an agent's subagents, one level in.
struct SubagentRowView: View {
  let subagent: AgentSidebarSubagent
  let isSelected: Bool
  let onActivate: () -> Void

  var body: some View {
    HoverableRow(isSelected: isSelected) { _ in
      HStack(spacing: 7) {
        AgentStatusMark(status: subagent.status).scaleEffect(0.85)
        Text(subagent.title).font(.callout).lineLimit(1)
        if let via = subagent.via {
          Text("via \(via)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        Spacer(minLength: 0)
        if subagent.kind == .workspace {
          Image(systemName: "square.on.square")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .help("Runs in its own workspace")
        }
      }
      .padding(.vertical, 3)
      .padding(.leading, 26)
      .padding(.trailing, 6)
      .contentShape(Rectangle())
      .onTapGesture(perform: onActivate)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { onActivate() }
  }
}

/// A folder (manual grouping) or a project (project grouping): a section
/// title that collapses its agents.
struct AgentSidebarSectionHeader: View {
  let title: String
  let systemImage: String
  let isCollapsed: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 6) {
        Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
        Text(title).fontWeight(.semibold).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
      }
      .font(.callout)
      .padding(.vertical, 5)
      .padding(.horizontal, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title), \(isCollapsed ? "collapsed" : "expanded")")
  }
}
