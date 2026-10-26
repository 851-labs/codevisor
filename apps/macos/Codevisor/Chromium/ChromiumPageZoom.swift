import Observation

@MainActor
@Observable
final class ChromiumPageZoom {
  private static let defaultPercent = 100
  private(set) var percent = ChromiumPageZoom.defaultPercent
  private(set) var canZoomOut = false
  private(set) var canZoomIn = false
  private(set) var canReset = false
  private(set) var presentationRequest = 0

  func update(percent: Int, canZoomOut: Bool, canZoomIn: Bool, canReset: Bool) {
    self.percent = percent
    self.canZoomOut = canZoomOut
    self.canZoomIn = canZoomIn
    self.canReset = canReset
  }

  func reset() { update(percent: Self.defaultPercent, canZoomOut: false, canZoomIn: false, canReset: false) }

  func present() { presentationRequest += 1 }
}
