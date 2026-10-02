import UIKit

/// Shares a simulator screenshot through the system share sheet, from the frontmost window.
@MainActor
enum SimulatorScreenshotSharing {
  static func share(_ data: Data, deviceName: String) {
    guard let image = UIImage(data: data),
      let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
      var presenter = scene.keyWindow?.rootViewController
    else { return }
    while let presented = presenter.presentedViewController { presenter = presented }
    let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
    sheet.title = "\(deviceName) Screenshot"
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
    }
    presenter.present(sheet, animated: true)
  }
}
