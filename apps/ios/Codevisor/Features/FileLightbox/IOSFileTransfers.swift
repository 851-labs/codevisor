import CodevisorCore
import CodevisorUI
import UIKit

enum IOSFileTransfers {
  static var transfers: FileTransfers {
    FileTransfers(saveAs: saveToFiles, share: share, reportFailure: reportFailure)
  }

  private static func saveToFiles(_ item: FileTransferItem) {
    present(item, failureTitle: "Unable to Save") { file in
      UIDocumentPickerViewController(forExporting: [file], asCopy: true)
    }
  }

  private static func share(_ item: FileTransferItem) {
    present(item, failureTitle: "Unable to Share") { file in
      let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = presenter?.view
      return sheet
    }
  }

  private static func present(
    _ item: FileTransferItem, failureTitle: String, make: @escaping @MainActor (URL) -> UIViewController
  ) {
    Task {
      do {
        let file = try await stage(item)
        presenter?.present(make(file), animated: true)
      } catch {
        reportFailure(failureTitle, "\(item.name) could not be prepared. \(error.localizedDescription)")
      }
    }
  }

  private static func reportFailure(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    presenter?.present(alert, animated: true)
  }

  private static var presenter: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  @concurrent
  private nonisolated static func stage(_ item: FileTransferItem) async throws -> URL {
    let directory = CodevisorAppVariant.temporaryURL()
      .appendingPathComponent("Codevisor-Shared-Files", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = (item.name as NSString).lastPathComponent
    let file = directory.appendingPathComponent(name.isEmpty ? "Attachment" : name)
    try await item.load().write(to: file, options: .atomic)
    return file
  }
}
