import CodevisorUI
import SwiftUI

struct ChromiumBrowserPaneView: View {
  @Bindable var model: ChromiumBrowserModel
  var isDetachedWindow = false
  @State private var hostClaim = 0
  var body: some View {
    VStack(spacing: 0) {
      if model.viewport != nil { ChromiumViewportControls(model: model) }
      ZStack {
        if let view = model.webView {
          ChromiumContent(view: view, model: model, isDetachedWindow: isDetachedWindow, claim: hostClaim)
        }
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
    .onAppear {
      if !isDetachedWindow { model.returnToWorkspace() }
      hostClaim += 1
      model.setVisible(true)
    }
    .onDisappear {
      if isDetachedWindow == (model.browserWindow != nil) { model.setVisible(false) }
    }
  }
}

private struct ChromiumContent: NSViewRepresentable {
  let view: CVChromiumView
  let model: ChromiumBrowserModel
  let isDetachedWindow: Bool
  let claim: Int
  func makeNSView(context: Context) -> ChromiumHostView {
    if !isDetachedWindow { model.returnToWorkspace() }
    let host = ChromiumHostView()
    host.claim(view)
    return host
  }
  func updateNSView(_ host: ChromiumHostView, context: Context) {
    host.claim(view)
  }
}

final class ChromiumHostView: NSView {
  private weak var hosted: CVChromiumView?
  private var keyObserver: (any NSObjectProtocol)?

  func claim(_ view: CVChromiumView) {
    hosted = view
    guard view.superview !== self else { return }
    view.removeFromSuperview()
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    keyObserver = nil
    guard let window else { return }
    keyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reclaimIfShown() }
    }
    reclaimIfShown()
  }

  private func reclaimIfShown() {
    guard let hosted, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return }
    claim(hosted)
  }
}
