import AppKit
import CodevisorUI

final class ChromiumPageFreezer {
  private static let hiddenDelay: Duration = .seconds(5 * 60)
  private var pending: Task<Void, Never>?
  private weak var frozen: CVChromiumView?

  func freezeLater(_ view: CVChromiumView, while canFreeze: @escaping () -> Bool) {
    pending?.cancel()
    pending = Task { [weak self, weak view] in
      try? await Task.sleep(for: Self.hiddenDelay)
      guard !Task.isCancelled, let view, canFreeze(), await Self.isQuiet(view), !Task.isCancelled else { return }
      self?.frozen = view
      _ = try? await view.cdp("Page.setWebLifecycleState", ["state": "frozen"])
    }
  }

  func thaw() async {
    cancel()
    guard let view = frozen else { return }
    frozen = nil
    _ = try? await view.cdp("Page.setWebLifecycleState", ["state": "active"])
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }

  private static func isQuiet(_ view: CVChromiumView) async -> Bool {
    let result = try? await view.cdp(
      "Runtime.evaluate", ["expression": BrowserPageActivity.playsMediaScript, "returnByValue": true])
    return (result?["result"] as? [String: Any])?["value"] as? Bool == false
  }
}
