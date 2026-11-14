import Observation

@testable import CodevisorCoreMac

@MainActor
@Observable
final class RecordedSurface {
  @ObservationIgnored let surface: ScreenSharingDesktopSurface
  private(set) var snapshot: ScreenSharingSurfaceSnapshot

  init(_ surface: ScreenSharingDesktopSurface) {
    self.surface = surface
    snapshot = surface.snapshot
    surface.onChange = { [weak self] in self?.snapshot = $0 }
  }

  func show(preferringDisplay displayId: String? = nil) {
    surface.setOnScreen(true, preferringDisplay: displayId)
  }

  func hide() {
    surface.setOnScreen(false, preferringDisplay: nil)
  }
}
