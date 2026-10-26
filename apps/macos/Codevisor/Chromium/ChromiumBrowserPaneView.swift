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
        ChromiumPagePlaceholder(snapshot: model.snapshot)
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
        } else if model.webView == nil, model.snapshot == nil {
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
    host.model = model
    host.claim(view)
    return host
  }
  func updateNSView(_ host: ChromiumHostView, context: Context) {
    host.claim(view)
  }
}

final class ChromiumHostView: NSView {
  weak var model: ChromiumBrowserModel?
  private weak var hosted: CVChromiumView?
  private var keyObserver: (any NSObjectProtocol)?
  private var reveal: Task<Void, Never>?

  func claim(_ view: CVChromiumView) {
    hosted = view
    guard let window, view.superview !== self else { return }
    let isWarm = view.superview is ChromiumBrowserStage && view.window === window && !view.isHidden
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
    view.isHidden = false
    if isWarm {
      view.alphaValue = 1
    } else {
      revealAfterPaint(view)
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard let window, newWindow !== window else { return }
    reveal?.cancel()
    reveal = nil
    guard let hosted, hosted.superview === self, let stage = ChromiumBrowserStage.stage(for: window) else { return }
    if hosted.alphaValue == 1 {
      stage.keepWarm(hosted) { [weak model] in await model?.captureSnapshot() }
    } else {
      stage.park(hosted)
    }
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
    if let hosted, !isHiddenOrHasHiddenAncestor { claim(hosted) }
  }

  private func reclaimIfShown() {
    guard let hosted, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return }
    claim(hosted)
  }

  private func revealAfterPaint(_ view: CVChromiumView) {
    reveal?.cancel()
    view.alphaValue = 0
    reveal = Task { [weak view] in
      if let view { await ChromiumPagePaint.waitUntilPainted(view) }
      guard !Task.isCancelled else { return }
      view?.alphaValue = 1
    }
  }
}
