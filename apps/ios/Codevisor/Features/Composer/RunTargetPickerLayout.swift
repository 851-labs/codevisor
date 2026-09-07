import SwiftUI

nonisolated enum RunTargetPickerRole {
  case machine, project, location, divider
}

nonisolated struct RunTargetPickerRoleKey: LayoutValueKey {
  static let defaultValue = RunTargetPickerRole.project
}

/// Allocate measured widths before SwiftUI lays out the labels. The machine
/// yields space first; the location can become an icon without hiding the
/// project. Large text (or an unusually narrow container) gets separate rows.
struct RunTargetPickerLayout: Layout {
  var stacksVertically: Bool
  var minimumMachineWidth: CGFloat
  var minimumProjectWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = frames(proposal: proposal, subviews: subviews)
    return CGSize(
      width: frames.map(\.maxX).max() ?? 0,
      height: frames.map(\.maxY).max() ?? 0
    )
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let frames = frames(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
    for (subview, frame) in zip(subviews, frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(frame.size)
      )
    }
  }

  private func frames(proposal: ProposedViewSize, subviews: Subviews) -> [CGRect] {
    let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
    let idealWidth = ideals.reduce(0, +)
    let proposedWidth = proposal.width ?? idealWidth
    let available = max(0, proposedWidth.isFinite ? proposedWidth : idealWidth)
    let roles = subviews.map { $0[RunTargetPickerRoleKey.self] }
    let minimums = zip(roles, ideals).map { role, ideal in
      switch role {
      case .machine: min(ideal, minimumMachineWidth)
      case .project: min(ideal, minimumProjectWidth)
      case .location: min(ideal, 44)
      case .divider: ideal
      }
    }
    if stacksVertically || available < minimums.reduce(0, +) {
      var y: CGFloat = 0
      return zip(subviews, roles).map { subview, role in
        if role == .divider {
          // Dividers retain their identity but disappear between stacked controls.
          return CGRect(x: 0, y: y, width: 0, height: 0)
        }
        let height = subview.sizeThatFits(ProposedViewSize(width: available, height: nil)).height
        defer { y += height }
        return CGRect(x: 0, y: y, width: available, height: height)
      }
    }

    var widths = ideals
    if let location = roles.firstIndex(of: .location) {
      let otherMinimums = minimums.enumerated().reduce(CGFloat.zero) {
        $0 + ($1.offset == location ? 0 : $1.element)
      }
      if otherMinimums + ideals[location] > available {
        widths[location] = minimums[location]
      }
    }
    // Keep the project's useful width before spending space on a long machine name.
    for role in [RunTargetPickerRole.machine, .project] {
      guard let index = roles.firstIndex(of: role) else { continue }
      let overflow = max(0, widths.reduce(0, +) - available)
      widths[index] -= min(overflow, max(0, widths[index] - minimums[index]))
    }
    let heights = zip(subviews, widths).map {
      $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height
    }
    let height = heights.max() ?? 0
    var x: CGFloat = 0
    return zip(widths, heights).map { width, childHeight in
      defer { x += width }
      return CGRect(x: x, y: (height - childHeight) / 2, width: width, height: childHeight)
    }
  }
}
