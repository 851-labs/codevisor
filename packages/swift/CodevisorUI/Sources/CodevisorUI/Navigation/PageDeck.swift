import Observation

@MainActor
@Observable
public final class PageDeck<Slot: Hashable, Route: Equatable> {
  public private(set) var pages: [RecentPages<Slot, Route>.Page] = []
  public private(set) var activeSlot: Slot?

  @ObservationIgnored private var history: RecentPages<Slot, Route>
  @ObservationIgnored private var activities: [Slot: WorkspaceActivity] = [:]
  @ObservationIgnored private var activation: UInt64 = 0

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
    activate(slot, notifiesShownPage: mounted?.route == route)
    return mounted == nil
  }

  public func showNothing() {
    guard activeSlot != nil else { return }

    activate(nil, notifiesShownPage: false)
  }

  private func activate(_ slot: Slot?, notifiesShownPage: Bool) {
    activeSlot = slot
    let mounted = Set(pages.map(\.id))
    activities = activities.filter { mounted.contains($0.key) }
    activation &+= 1
    let current = activation
    for (id, activity) in activities where id != slot {
      activity.setActive(false, notifiesListeners: true)
      guard activation == current else { return }
    }
    if let slot { activities[slot]?.setActive(true, notifiesListeners: notifiesShownPage) }
  }
}
