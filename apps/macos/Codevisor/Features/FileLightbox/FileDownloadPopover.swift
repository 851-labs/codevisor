import AppKit
import SwiftUI

enum FileDownloadPopover {
  private static var shown: NSPopover?

  static func present(_ download: FileDownloads.Download) {
    guard let anchor = MenuOrigin.shared.anchor else { return }

    shown?.close()
    let popover = NSPopover()
    popover.behavior = .transient
    let content = FileDownloadPopoverContent(latest: download) { [weak popover] in popover?.close() }
    let controller = NSHostingController(rootView: content)
    controller.sizingOptions = .preferredContentSize
    popover.contentViewController = controller
    popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
    shown = popover
  }
}

private struct FileDownloadPopoverContent: View {
  @State var latest: FileDownloads.Download
  let close: () -> Void
  var downloads: FileDownloads = .shared

  var body: some View {
    FileDownloadStatus(download: latest)
      .onChange(of: downloads.download(latest.id)) { _, download in
        guard let download else { return close() }

        latest = download
      }
  }
}
