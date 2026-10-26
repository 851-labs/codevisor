import AppKit

enum ChromiumPagePaint {
  private static let commitLimit: Duration = .seconds(10)
  private static let paintLimit: Duration = .milliseconds(300)
  private static let pollInterval: Duration = .milliseconds(16)
  private static let presentationDelay: Duration = .milliseconds(17)
  private static let presentedFrameScript = """
    new Promise(done => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(() => done(true)))))
    """

  static func waitUntilPainted(_ view: CVChromiumView) async {
    await waitForCommittedPage(view)
    guard !Task.isCancelled else { return }
    await ChromiumDeadline.run(within: paintLimit) {
      _ = try? await view.cdp(
        "Runtime.evaluate", ["expression": presentedFrameScript, "awaitPromise": true, "returnByValue": true])
      try? await Task.sleep(for: presentationDelay)
    }
  }

  private static func waitForCommittedPage(_ view: CVChromiumView) async {
    let clock = ContinuousClock()
    let deadline = clock.now + commitLimit
    while !view.hasCommittedPage, clock.now < deadline, !Task.isCancelled {
      try? await Task.sleep(for: pollInterval)
    }
  }
}
