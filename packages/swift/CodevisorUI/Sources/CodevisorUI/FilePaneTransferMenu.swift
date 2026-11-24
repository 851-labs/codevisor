import SwiftUI
import UniformTypeIdentifiers

public struct FilePaneTransferMenu: View {
  private let model: FilePaneModel
  private let transfers: FileTransfers

  public init(model: FilePaneModel, transfers: FileTransfers) {
    self.model = model
    self.transfers = transfers
  }

  public var body: some View {
    if !model.isBrowsing {
      FileMenuContent(menu)
    }
  }

  private var menu: FileMenu {
    let item = item
    return FileMenu(title: item.name, sections: [transferActions(for: item) + [copyAction(for: item)]], share: item)
  }

  private var item: FileTransferItem {
    let path = model.path
    let client = model.client
    let name = model.title
    let type = UTType(filenameExtension: (name as NSString).pathExtension)
    return FileTransferItem(name: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream") {
      try await FileDocumentLocation.data(path: path, client: client)
    }
  }

  private func transferActions(for item: FileTransferItem) -> [FileMenuAction] {
    var actions: [FileMenuAction] = []
    if let download = transfers.download {
      actions.append(FileMenuAction("Download", systemImage: FileTransfers.downloadSymbol) { download(item) })
    }
    if let saveAs = transfers.saveAs {
      actions.append(FileMenuAction(FileTransfers.saveAsTitle, systemImage: "square.and.arrow.down") { saveAs(item) })
    }
    return actions
  }

  private func copyAction(for item: FileTransferItem) -> FileMenuAction {
    let report = transfers.reportFailure
    return FileMenuAction("Copy", systemImage: "doc.on.doc") {
      Task {
        if await AttachmentClipboard.copy(item) { return }
        report?("Unable to Copy", "\(item.name) could not be copied. Please try again.")
      }
    }
  }
}
