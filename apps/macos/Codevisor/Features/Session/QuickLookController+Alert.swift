import AppKit
import CodevisorUI

extension QuickLookController {
  /// The app's Quick Look controller: failures show as a sheet on the key
  /// window so a click that cannot preview never fails silently.
  static func withAlerts() -> QuickLookController {
    let controller = QuickLookController()
    controller.onFailure = { name, error in
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Unable to Preview Attachment"
      alert.informativeText = "\(name) could not be prepared for Quick Look. \(error.localizedDescription)"
      alert.addButton(withTitle: "OK")
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window)
      } else {
        alert.runModal()
      }
    }
    return controller
  }
}
