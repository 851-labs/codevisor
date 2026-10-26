import Foundation

@MainActor
final class ChromiumBrowserModels {
  static let shared = ChromiumBrowserModels()

  private final class Holder {
    weak var pane: BrowserPane?
    init(_ pane: BrowserPane) { self.pane = pane }
  }

  private var models: [UUID: ChromiumBrowserModel] = [:]
  private var holders: [UUID: [Holder]] = [:]
  private var newTabs: [UUID: Bool] = [:]

  func acquire(_ paneId: UUID, make: () -> ChromiumBrowserModel) -> ChromiumBrowserModel {
    if let existing = models[paneId] { return existing }
    let created = make()
    models[paneId] = created
    if let focusesAddress = newTabs.removeValue(forKey: paneId) {
      created.openAsNewTab()
      if focusesAddress { created.address.focus() }
    }
    return created
  }

  func expectNewTab(_ paneId: UUID, focusingAddress: Bool = false) {
    newTabs[paneId] = focusingAddress
  }

  func wire(_ pane: BrowserPane) {
    var current = others(than: pane)
    current.append(Holder(pane))
    holders[pane.id] = current
    pane.wiring?(pane.model)
  }

  func release(_ pane: BrowserPane) {
    let remaining = others(than: pane)
    if let next = remaining.last?.pane {
      holders[pane.id] = remaining
      next.wiring?(next.model)
      return
    }
    holders[pane.id] = nil
    guard let model = models.removeValue(forKey: pane.id) else { return }
    model.teardown()
    if !models.values.contains(where: { $0.machineId == model.machineId }) {
      ChromiumSpareBrowsers.shared.discard(machineId: model.machineId)
    }
  }

  private func others(than pane: BrowserPane) -> [Holder] {
    holders[pane.id, default: []].filter { $0.pane != nil && $0.pane !== pane }
  }
}
