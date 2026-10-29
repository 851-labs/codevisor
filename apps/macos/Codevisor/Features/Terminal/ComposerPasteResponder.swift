import AppKit

@MainActor
final class ComposerPasteResponder: NSResponder, NSMenuItemValidation {
  var composer: (() -> SubmittingTextView?)?
  private weak var window: NSWindow?

  func attach(to window: NSWindow?) {
    guard window !== self.window else { return }
    detach()
    guard let window else { return }
    nextResponder = window.nextResponder
    window.nextResponder = self
    self.window = window
  }

  func detach() {
    guard let window else { return }
    let previous = sequence(first: window as NSResponder, next: \.nextResponder)
      .first { $0.nextResponder === self }
    previous?.nextResponder = nextResponder
    nextResponder = nil
    self.window = nil
  }

  nonisolated override func responds(to selector: Selector!) -> Bool {
    guard selector == #selector(NSText.paste(_:)), Thread.isMainThread else {
      return super.responds(to: selector)
    }
    return MainActor.assumeIsolated { composer?() != nil }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    composer?()?.validateUserInterfaceItem(item) ?? false
  }

  @objc func paste(_ sender: Any?) {
    guard let composer = composer?(), composer.window?.makeFirstResponder(composer) == true
    else { return }
    composer.paste(sender)
  }
}
