import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class BrowserPane: Pane {
  let id: UUID
  let kind: PaneKind = .browser
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  let model: ChromiumBrowserModel
  var wiring: ((ChromiumBrowserModel) -> Void)? {
    didSet { ChromiumBrowserModels.shared.wire(self) }
  }

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    model = ChromiumBrowserModels.shared.acquire(descriptor.id) {
      ChromiumBrowserModel(
        paneId: descriptor.id, machineId: context.machine.id, machineName: context.machine.name,
        initialURL: descriptor.browserURL ?? "https://www.google.com/",
        client: context.client ?? CodevisorServerClient(config: context.machine.serverConfig),
        resolveBaseURL: context.resolveHTTPBaseURL ?? { context.machine.baseURL }
      )
    }
  }

  func makeView() -> AnyView {
    AnyView(ChromiumBrowserPaneView(model: model))
  }
  func focus() {
    model.webView?.focusPage()
  }
  func visibilityChanged(_ visible: Bool) { model.setVisible(visible) }
  func willDelete() async { ChromiumBrowserModels.shared.release(self) }
  func detach() { ChromiumBrowserModels.shared.release(self) }
}
