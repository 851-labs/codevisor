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

  func acquire(_ paneId: UUID, make: () -> ChromiumBrowserModel) -> ChromiumBrowserModel {
    if let existing = models[paneId] { return existing }
    let created = make()
    models[paneId] = created
    return created
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
    models.removeValue(forKey: pane.id)?.teardown()
  }

  private func others(than pane: BrowserPane) -> [Holder] {
    holders[pane.id, default: []].filter { $0.pane != nil && $0.pane !== pane }
  }
}
