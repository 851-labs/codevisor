import Foundation

/// Screen-sharing preferences that belong to a machine rather than a pane
/// (851-2340), keyed by machine id, so they work for saved machines
/// (`remote-…`) and Codevisor Cloud ones (`cloud:<device>`) alike.
public struct ScreenSharingMachinePreferences {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  private static func key(_ machineId: String) -> String { "screenSharing.dynamicResolution.\(machineId)" }

  /// Dynamic Resolution: on unless the user turned it off for this machine.
  public func dynamicResolution(machineId: String) -> Bool {
    defaults.object(forKey: Self.key(machineId)) as? Bool ?? true
  }

  public func setDynamicResolution(_ enabled: Bool, machineId: String) {
    defaults.set(enabled, forKey: Self.key(machineId))
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
