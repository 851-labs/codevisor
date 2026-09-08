import CodevisorUI
import SwiftUI

struct ChromiumBrowserPaneView: View {
  @Bindable var model: ChromiumBrowserModel
  var body: some View {
    VStack(spacing: 0) {
      if model.viewport != nil { ChromiumViewportControls(model: model) }
      ZStack {
        if let view = model.webView { ChromiumContent(view: view) }
        if let error = model.errorMessage {
          ContentUnavailableView {
            Label("Couldn’t Load Page", systemImage: "network.slash")
          } description: {
            Text(error)
          } actions: {
            Button("Try Again") { model.reload() }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
        } else if model.webView == nil {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { model.setVisible(true) }
    .onDisappear { model.setVisible(false) }
  }
}

private struct ChromiumContent: NSViewRepresentable {
  let view: CVChromiumView
  func makeNSView(context: Context) -> CVChromiumView { view }
  func updateNSView(_ nsView: CVChromiumView, context: Context) {}
}
