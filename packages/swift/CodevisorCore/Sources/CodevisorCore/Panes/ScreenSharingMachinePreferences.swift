import Foundation

/// Screen-sharing preferences that belong to a machine rather than a pane
/// (851-2340), keyed by machine id, so they work for saved machines
/// (`remote-…`) and Codevisor Cloud ones (`cloud:<device>`) alike.
public struct ScreenSharingMachinePreferences {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  private static func key(_ machineId: String) -> String { "screenSharing.dynamicResolution.\(machineId)" }

  /// Dynamic Resolution: off unless the user turned it on for this machine (851-2481).
  public func dynamicResolution(machineId: String) -> Bool {
    resetDynamicResolutionOnce()
    return defaults.object(forKey: Self.key(machineId)) as? Bool ?? false
  }

  public func setDynamicResolution(_ enabled: Bool, machineId: String) {
    resetDynamicResolutionOnce()
    defaults.set(enabled, forKey: Self.key(machineId))
  }

  /// Set once every machine's Dynamic Resolution choice has been cleared for the new default.
  private static let dynamicResolutionResetKey = "screenSharing.dynamicResolutionResetToOff"

  /// 851-2481: when Dynamic Resolution became off by default, every machine went back to off,
  /// including those saved as on under the old default. Once; later choices are kept.
  private func resetDynamicResolutionOnce() {
    guard !defaults.bool(forKey: Self.dynamicResolutionResetKey) else { return }
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("screenSharing.dynamicResolution.") {
      defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: Self.dynamicResolutionResetKey)
  }

  /// HDR (851-2480): off unless the user turned it on for this machine.
  public func highDynamicRange(machineId: String) -> Bool {
    defaults.object(forKey: "screenSharing.highDynamicRange.\(machineId)") as? Bool ?? false
  }

  public func setHighDynamicRange(_ enabled: Bool, machineId: String) {
    defaults.set(enabled, forKey: "screenSharing.highDynamicRange.\(machineId)")
  }

  /// Whether the machine's sound plays (on unless turned off) and how loud, 0…1 (851-2379).
  public func sound(machineId: String) -> (enabled: Bool, volume: Double) {
    (
      defaults.object(forKey: "screenSharing.soundEnabled.\(machineId)") as? Bool ?? true,
      defaults.object(forKey: "screenSharing.soundVolume.\(machineId)") as? Double ?? 1
    )
  }

  public func setSound(enabled: Bool, volume: Double, machineId: String) {
    defaults.set(enabled, forKey: "screenSharing.soundEnabled.\(machineId)")
    defaults.set(volume, forKey: "screenSharing.soundVolume.\(machineId)")
  }

  /// When video last arrived from this machine, for the settings sheet (851-2367).
  public func lastConnected(machineId: String) -> Date? {
    defaults.object(forKey: "screenSharing.lastConnected.\(machineId)") as? Date
  }

  public func setLastConnected(_ date: Date, machineId: String) {
    defaults.set(date, forKey: "screenSharing.lastConnected.\(machineId)")
  }
}
