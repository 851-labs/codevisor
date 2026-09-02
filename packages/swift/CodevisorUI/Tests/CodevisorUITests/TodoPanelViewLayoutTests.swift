#if canImport(AppKit)
  import ACPKit
  import AppKit
  import SwiftUI
  import Testing
  @testable import CodevisorUI

  @Suite("Todo panel layout")
  @MainActor
  struct TodoPanelViewLayoutTests {
    private let maximumExpandedHeight: CGFloat = 240
    private let proposedWidth: CGFloat = 410

    @Test("A short expanded plan hugs its rows")
    func shortPlanHugsContent() throws {
      let plan = Plan(entries: [
        PlanEntry(content: "Read the existing code", priority: .high, status: .completed),
        PlanEntry(content: "Implement the change", priority: .medium, status: .inProgress),
        PlanEntry(content: "Add tests", priority: .low, status: .pending),
      ])

      let naturalHeight = try renderedHeight(plan: plan, maximumExpandedHeight: nil)
      let cappedHeight = try renderedHeight(
        plan: plan,
        maximumExpandedHeight: maximumExpandedHeight
      )

      #expect(abs(cappedHeight - naturalHeight) < 1)
      #expect(!containsScrollView(plan: plan, height: cappedHeight))
    }

    @Test("An overflowing plan stops at the scroll cap")
    func overflowingPlanUsesCap() throws {
      let plan = Plan(
        entries: (0..<30).map { index in
          PlanEntry(
            content: "Plan entry \(index)",
            priority: .medium,
            status: index == 0 ? .inProgress : .pending
          )
        }
      )

      let collapsedHeight = try renderedHeight(
        plan: plan,
        isExpanded: false,
        maximumExpandedHeight: maximumExpandedHeight
      )
      let expandedHeight = try renderedHeight(
        plan: plan,
        maximumExpandedHeight: maximumExpandedHeight
      )

      let revealedHeight = expandedHeight - collapsedHeight
      #expect(revealedHeight >= maximumExpandedHeight + 5)
      #expect(revealedHeight <= maximumExpandedHeight + 7)
      #expect(containsScrollView(plan: plan, height: expandedHeight))
    }

    private func renderedHeight(
      plan: Plan,
      isExpanded: Bool = true,
      maximumExpandedHeight: CGFloat?
    ) throws -> CGFloat {
      let renderer = ImageRenderer(
        content: TodoPanelView(
          plan: plan,
          isExpanded: .constant(isExpanded),
          maximumExpandedHeight: maximumExpandedHeight
        )
        .frame(width: proposedWidth)
      )
      renderer.proposedSize = ProposedViewSize(width: proposedWidth, height: 1_000)

      return try #require(renderer.nsImage).size.height
    }

    private func containsScrollView(plan: Plan, height: CGFloat) -> Bool {
      let hostingView = NSHostingView(
        rootView: TodoPanelView(
          plan: plan,
          isExpanded: .constant(true),
          maximumExpandedHeight: maximumExpandedHeight
        )
        .frame(width: proposedWidth)
      )
      hostingView.frame = CGRect(x: 0, y: 0, width: proposedWidth, height: height)
      hostingView.layoutSubtreeIfNeeded()

      return containsScrollView(in: hostingView)
    }

    private func containsScrollView(in view: NSView) -> Bool {
      if view is NSScrollView { return true }
      return view.subviews.contains { containsScrollView(in: $0) }
    }
  }
#endif
