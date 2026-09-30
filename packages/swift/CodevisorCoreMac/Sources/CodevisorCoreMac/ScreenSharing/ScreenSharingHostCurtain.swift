import CoreGraphics

/// The host's own screens go dark while someone controls it, like Apple Screen Sharing's High
/// Performance mode (851-2382), so nobody nearby sees or follows what the viewer does. Every
/// physical display gets an all-zero gamma table: the panel shows black while its pixels, and so
/// the capture, stay as they are (on tuftlord the stream's brightness didn't change while the
/// display was dark). macOS restores gamma when the process that set it exits, so a crash can't
/// leave the host dark.
@MainActor
final class ScreenSharingHostCurtain {
  struct System {
    /// The displays to darken: every online display but the host's own virtual ones.
    var physicalDisplays: () -> [CGDirectDisplayID]
    var darken: (CGDirectDisplayID) -> Void
    var restore: () -> Void
  }

  private let system: System
  private(set) var isDrawn = false

  init(system: System = .live) { self.system = system }

  func draw() {
    isDrawn = true
    apply()
  }

  /// A display appearing or changing mode (a mirror, a resize) may reset its gamma; while drawn,
  /// darken again.
  func displaysChanged() {
    if isDrawn { apply() }
  }

  func open() {
    guard isDrawn else { return }
    isDrawn = false
    system.restore()
  }

  private func apply() {
    for display in system.physicalDisplays() { system.darken(display) }
  }
}

extension ScreenSharingHostCurtain.System {
  @MainActor static let live = Self(
    physicalDisplays: {
      ScreenSharingDisplayIdentity.online().filter { !$0.isVirtual }.map(\.id)
    },
    darken: { display in
      let zero = [CGGammaValue](repeating: 0, count: 256)
      _ = CGSetDisplayTransferByTable(display, 256, zero, zero, zero)
    },
    restore: { CGDisplayRestoreColorSyncSettings() })
}
