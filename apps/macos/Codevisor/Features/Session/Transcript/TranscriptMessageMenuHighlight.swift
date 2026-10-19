import AppKit
import Observation

@MainActor
@Observable
final class TranscriptMessageMenuHighlight {
  static let shared = TranscriptMessageMenuHighlight()

  private(set) var messageID: String?
  @ObservationIgnored private lazy var closeObserver = MenuCloseObserver { [weak self] in
    self?.messageID = nil
  }

  func highlight(_ messageID: String, whileShowing menu: NSMenu) {
    self.messageID = messageID
    menu.delegate = closeObserver
  }

  private final class MenuCloseObserver: NSObject, NSMenuDelegate {
    let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
      self.onClose = onClose
    }

    func menuDidClose(_: NSMenu) {
      MainActor.assumeIsolated { onClose() }
    }
  }
}
