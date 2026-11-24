import AppKit
import CodevisorCore
import CodevisorUI

enum MacFileTransfers {
  static var transfers: FileTransfers {
    FileTransfers(download: download, saveAs: saveAs, share: share, reportFailure: reportFailure)
  }

  private static func download(_ item: FileTransferItem) {
    guard let download = FileDownloads.shared.start(item) else { return }

    FileDownloadPopover.present(download)
  }

  private static func saveAs(_ item: FileTransferItem) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = fileName(of: item)
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    Task {
      do {
        try await write(item, to: destination)
      } catch {
        reportFailure("Unable to Save", "\(item.name) could not be saved. \(error.localizedDescription)")
      }
    }
  }

  private static func share(_ item: FileTransferItem) {
    guard let view = NSApp.keyWindow?.contentView, let window = view.window else { return }
    let anchor = CGRect(origin: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), size: .zero)
    Task {
      do {
        let file = try await stage(item)
        NSSharingServicePicker(items: [file]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
      } catch {
        reportFailure("Unable to Share", "\(item.name) could not be prepared. \(error.localizedDescription)")
      }
    }
  }

  private static func reportFailure(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return _ = alert.runModal() }

    alert.beginSheetModal(for: window)
  }

  @concurrent
  private nonisolated static func write(_ item: FileTransferItem, to destination: URL) async throws {
    try await item.load().write(to: destination, options: .atomic)
  }

  @concurrent
  private nonisolated static func stage(_ item: FileTransferItem) async throws -> URL {
    let directory = CodevisorAppVariant.temporaryURL()
      .appendingPathComponent("Codevisor-Shared-Files", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(fileName(of: item))
    try await item.load().write(to: file, options: .atomic)
    return file
  }

  private nonisolated static func fileName(of item: FileTransferItem) -> String {
    let name = (item.name as NSString).lastPathComponent
    return name.isEmpty ? "Attachment" : name
  }
}
