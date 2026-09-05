#if canImport(AppKit)
  import AppKit
  import CodevisorTestSupport

  @MainActor
  final class FocusTestWindow: NSWindow {
    private let responderChanged = TestSignal()

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
      let accepted = super.makeFirstResponder(responder)
      responderChanged.signal()
      return accepted
    }

    func waitForResponder(_ matches: (NSResponder?) -> Bool) async {
      while !matches(firstResponder) {
        let next = responderChanged.value + 1
        await responderChanged.wait(for: next)
      }
    }
  }
#endif
