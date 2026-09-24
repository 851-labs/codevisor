import CodevisorUI
import Foundation

/// A window's live browser pages by pane id, kept current by the pane groups
/// that own them, so a sidebar row finds its page's title and favicon in O(1)
/// instead of scanning every group. Deliberately not observable: like the
/// groups themselves it is an identity cache, updated while panes build.
@MainActor
final class BrowserPaneIndex {
  private struct Entry {
    weak var model: ChromiumBrowserModel?
    let owner: ObjectIdentifier
  }

  private var entries: [UUID: Entry] = [:]

  func model(paneId: UUID) -> ChromiumBrowserModel? {
    entries[paneId]?.model
  }

  /// Mirrors a group's live panes after they change. A pane moving between
  /// groups is registered by its new owner; the old owner's removal only
  /// clears an entry it still owns.
  func update(owner: ObjectIdentifier, previous: [UUID: any Pane], current: [UUID: any Pane]) {
    for (id, pane) in previous where pane is BrowserPane && current[id] == nil {
      if entries[id]?.owner == owner { entries[id] = nil }
    }
    for (id, pane) in current {
      guard let browser = pane as? BrowserPane else { continue }
      entries[id] = Entry(model: browser.model, owner: owner)
    }
  }
}
