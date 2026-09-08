import CodevisorCore
import CodevisorUI
import SwiftUI
import WebKit

extension WorkspaceScreen {
  @discardableResult
  func openBrowserLink(from sourceId: UUID, url: URL?, configuration: WKWebViewConfiguration?) -> WKWebView? {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == sourceId }) else { return nil }
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .browser, name: "Browser", terminalKey: id.uuidString,
      browserURL: url.flatMap { BrowserLocation.sharedURL($0.absoluteString) }?.absoluteString)
    state.panes.insert(pane, at: index + 1)
    let model = browserPaneModel(for: pane)
    let popup: WKWebView?
    if let configuration {
      popup = model.adoptPopup(configuration: configuration)
      state.selectedPaneId = id
    } else {
      popup = nil
      if let url { model.navigate(to: url.absoluteString) }
    }
    paneBinding.wrappedValue = state
    publishPane(pane)
    return popup
  }
}
