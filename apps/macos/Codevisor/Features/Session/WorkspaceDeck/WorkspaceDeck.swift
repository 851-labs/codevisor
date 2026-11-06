import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceDeck<Page: View>: View {
  let active: WorkspaceDeckRoute?
  @ViewBuilder let page: (WorkspaceDeckRoute) -> Page
  @Environment(AppEnvironment.self) private var environment
  @State private var history = RecentPages<WorkspaceDeckSlot, WorkspaceDeckRoute>(capacity: 5)
  @State private var focusAnchor = DetailColumnFocusAnchor()
  @State private var activities: [WorkspaceDeckSlot: WorkspaceActivity] = [:]
  @State private var sizes = WorkspaceDeckSizes()

  var body: some View {
    WorkspaceDeckLayout {
      ForEach(history.pages(showing: active, in: activeSlot, keeping: floatingSlots)) { mounted in
        let isActive = mounted.id == activeSlot
        let frozenSize = isActive ? nil : sizes.frozenSize(for: mounted.id)
        WorkspaceDeckPage(route: mounted.route, activity: activity(for: mounted.id)) {
          page(mounted.route)
        }
        .equatable()
        .frame(width: frozenSize?.width, height: frozenSize?.height)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
      }
    }
    .onGeometryChange(for: CGSize.self, of: \.size) { sizes.current = $0 }
    .background(DetailColumnFocusAnchor.Capture(anchor: focusAnchor).frame(width: 0, height: 0))
    .onChange(of: activeSlot, initial: true) { previous, slot in
      sizes.show(slot, hiding: previous)
      syncActivities(active: slot)
      guard let active, let slot else { return }
      focusAnchor.releaseFocus()
      history.show(active, in: slot, keeping: floatingSlots)
    }
  }

  private func activity(for slot: WorkspaceDeckSlot) -> WorkspaceActivity {
    activities[slot] ?? WorkspaceActivity(isActive: slot == activeSlot)
  }

  private func syncActivities(active: WorkspaceDeckSlot?) {
    let mounted = Set(history.pages(showing: self.active, in: active, keeping: floatingSlots).map(\.id))
    activities = activities.filter { mounted.contains($0.key) }
    sizes.keep(mounted)
    for slot in mounted where activities[slot] == nil {
      activities[slot] = WorkspaceActivity(isActive: slot == active)
    }
    for (slot, activity) in activities where activity.isActive != (slot == active) {
      activity.isActive = slot == active
    }
  }

  private var floatingSlots: Set<WorkspaceDeckSlot> {
    Set(FloatingPanes.shared.workspaceIds.map(WorkspaceDeckSlot.workspace))
  }

  private var activeSlot: WorkspaceDeckSlot? {
    active.map(slot(for:))
  }

  private func slot(for route: WorkspaceDeckRoute) -> WorkspaceDeckSlot {
    switch route {
    case let .session(_, sessionId):
      environment.workspaces.workspaceId(forSession: sessionId).map(WorkspaceDeckSlot.workspace) ?? .session(sessionId)
    case let .workspace(_, workspaceId):
      .workspace(workspaceId)
    case let .bot(_, botId):
      .bot(botId)
    }
  }
}
