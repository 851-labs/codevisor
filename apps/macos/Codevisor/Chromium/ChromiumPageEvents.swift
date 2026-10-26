import Foundation

enum ChromiumPageEvents {
  static func connect(_ view: CVChromiumView, to model: ChromiumBrowserModel, token: UUID, adopted: Bool) {
    connectPage(view, to: model, token: token)
    connectNavigation(view, to: model, token: token)
    view.browserReady = { [weak model, weak view] in
      Task { @MainActor [weak model, weak view] in
        guard let model, let view, model.isCurrent(token) else { return }
        await model.browserBecameReady(view, token: token, adopted: adopted)
      }
    }
  }

  private static func connectPage(_ view: CVChromiumView, to model: ChromiumBrowserModel, token: UUID) {
    view.zoomChanged = { [weak model] percent, canZoomOut, canZoomIn, canReset in
      Task { @MainActor [weak model] in
        guard let model, model.isCurrent(token) else { return }
        model.pageZoom.update(percent: percent, canZoomOut: canZoomOut, canZoomIn: canZoomIn, canReset: canReset)
      }
    }
    view.viewportScaleChanged = { [weak model, weak view] scale in
      Task { @MainActor [weak model, weak view] in
        guard let model, let view, model.isCurrent(token), let viewport = model.viewport else { return }
        var metrics = viewport.parameters
        metrics["scale"] = scale
        metrics["dontSetVisibleSize"] = true
        _ = try? await view.cdp("Emulation.setDeviceMetricsOverride", metrics)
      }
    }
    view.faviconChanged = { [weak model] data in
      Task { @MainActor [weak model] in
        guard let model, model.isCurrent(token) else { return }
        model.updateFavicon(data)
      }
    }
    view.findResult = { [weak model] matches, activeMatch, finished in
      MainActor.assumeIsolated { model?.finder.publish(matches: matches, activeMatch: activeMatch, finished: finished) }
    }
  }

  private static func connectNavigation(_ view: CVChromiumView, to model: ChromiumBrowserModel, token: UUID) {
    view.openLink = { [weak model] address, destination in
      model?.onOpenLink?(address, destination.workspaceDestination, nil) ?? false
    }
    view.adoptPopup = { [weak model] popup, address, destination in
      model?.onOpenLink?(address, destination.workspaceDestination, popup) ?? false
    }
    view.browserClosed = { [weak model] closedByPage in
      guard let model, model.isCurrent(token) else { return }
      model.browserClosed(byPage: closedByPage)
    }
    view.stateChanged = { [weak model] address, title, loading, back, forward in
      Task { @MainActor [weak model] in
        guard let model, model.isCurrent(token) else { return }
        model.applyState(address: address, title: title, loading: loading, back: back, forward: forward)
      }
    }
    view.loadFailed = { [weak model] code, message, address in
      Task { @MainActor [weak model] in
        guard let model, model.isCurrent(token) else { return }
        await model.pageFailed(code: code, message: message, address: address, token: token)
      }
    }
  }
}
