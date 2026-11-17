import Observation

@MainActor
@Observable
public final class PageDeck<Slot: Hashable, Route: Equatable> {
  public private(set) var pages: [RecentPages<Slot, Route>.Page] = []
  public private(set) var activeSlot: Slot?

  @ObservationIgnored private var history: RecentPages<Slot, Route>
  @ObservationIgnored private var activities: [Slot: WorkspaceActivity] = [:]

  public init(capacity: Int) {
    history = RecentPages(capacity: capacity)
  }

  public func activity(for slot: Slot) -> WorkspaceActivity {
    if let activity = activities[slot] { return activity }

    let activity = WorkspaceActivity(isActive: slot == activeSlot)
    activities[slot] = activity
    return activity
  }

  @discardableResult
  public func show(_ route: Route, in slot: Slot) -> Bool {
    let mounted = history.pages.first { $0.id == slot }
    guard slot != activeSlot || mounted?.route != route else { return false }

    history.show(route, in: slot)
    pages = history.pages
    activate(slot)
    return mounted == nil
  }

  public func showNothing() {
    guard activeSlot != nil else { return }

    activate(nil)
  }

  private func activate(_ slot: Slot?) {
    activeSlot = slot
    let mounted = Set(pages.map(\.id))
    activities = activities.filter { mounted.contains($0.key) }
    for (id, activity) in activities where activity.isActive != (id == slot) {
      activity.isActive = id == slot
    }
  }
}
