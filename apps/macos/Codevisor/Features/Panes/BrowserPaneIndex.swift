import CodevisorUI
import Foundation

@MainActor
final class BrowserPaneIndex {
  private final class Entry {
    weak var model: ChromiumBrowserModel?
    let owner: ObjectIdentifier

    init(model: ChromiumBrowserModel, owner: ObjectIdentifier) {
      self.model = model
      self.owner = owner
    }
  }

  private var entries: [UUID: Entry] = [:]

  func model(paneId: UUID) -> ChromiumBrowserModel? {
    entries[paneId]?.model
  }

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
