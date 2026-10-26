import AppKit

enum ChromiumPageSnapshot {
  private static let captureLimit: Duration = .milliseconds(500)
  private static let parameters: [String: Any] = [
    "format": "jpeg", "quality": 70, "fromSurface": true, "optimizeForSpeed": true,
  ]

  static func capture(_ view: CVChromiumView) async -> Data? {
    var snapshot: Data?
    await ChromiumDeadline.run(within: captureLimit) {
      let result = try? await view.cdp("Page.captureScreenshot", parameters)
      snapshot = (result?["data"] as? String).flatMap { Data(base64Encoded: $0) }
    }
    return snapshot
  }
}
