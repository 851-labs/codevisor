import Observation

@MainActor
@Observable
final class ChromiumPageDialogs {
  private(set) var current: CVChromiumPageDialog?

  func opened(_ dialog: CVChromiumPageDialog) {
    current?.dismiss()
    current = dialog
  }

  func closed() { current = nil }

  func accept(text: String) {
    current?.accept(withText: text)
    current = nil
  }

  func dismiss() {
    current?.dismiss()
    current = nil
  }
}
