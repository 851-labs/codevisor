import Observation

@MainActor
@Observable
final class ChromiumPageDialogs {
  private(set) var current: CVChromiumPageDialog?

  func opened(_ dialog: CVChromiumPageDialog) {
    take()?.dismiss()
    current = dialog
  }

  func closed() { _ = take() }

  func accept(text: String) { take()?.accept(withText: text) }

  func dismiss() { take()?.dismiss() }

  private func take() -> CVChromiumPageDialog? {
    guard let dialog = current else { return nil }

    withExtendedLifetime(dialog) { current = nil }
    return dialog
  }
}
