#if os(iOS)
  import UIKit
  import WebKit

  extension BrowserPaneModel {
    public func webView(
      _ webView: WKWebView, contextMenuConfigurationForElement element: WKContextMenuElementInfo,
      completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
      completionHandler(
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
          guard let self, let url = element.linkURL, Self.navigationURL(url.absoluteString) != nil,
            self.onOpenLink != nil
          else { return UIMenu(children: suggested) }
          let open = UIAction(title: "Open Link in New Tab", image: UIImage(systemName: "plus.square.on.square")) {
            [weak self] _ in self?.onOpenLink?(url)
          }
          return UIMenu(children: [open] + suggested)
        })
    }
  }
#endif
