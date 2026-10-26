import CodevisorCore

public enum BrowserPaneUpdate {
  public static func navigated(_ pane: PaneDescriptorState, to url: String, title: String) -> PaneDescriptorState? {
    var updated = pane
    updated.browserURL = url
    updated.name = title
    if !BrowserFaviconStore.sameOrigin(url, pane.browserURL) { updated.browserFavicon = nil }
    return updated == pane ? nil : updated
  }

  public static func favicon(
    _ reference: String, savedFor page: String, on pane: PaneDescriptorState
  ) -> PaneDescriptorState? {
    guard pane.browserFavicon != reference, BrowserFaviconStore.sameOrigin(pane.browserURL, page) else { return nil }

    var updated = pane
    updated.browserFavicon = reference
    return updated
  }
}
