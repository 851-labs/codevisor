import Foundation

public struct ScreenSharingMachinePreferences {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  private static func key(_ machineId: String) -> String { "screenSharing.dynamicResolution.\(machineId)" }

  public func dynamicResolution(machineId: String) -> Bool {
    resetDynamicResolutionOnce()
    return defaults.object(forKey: Self.key(machineId)) as? Bool ?? false
  }

  public func setDynamicResolution(_ enabled: Bool, machineId: String) {
    resetDynamicResolutionOnce()
    defaults.set(enabled, forKey: Self.key(machineId))
  }

  private static let dynamicResolutionResetKey = "screenSharing.dynamicResolutionResetToOff"

  private func resetDynamicResolutionOnce() {
    guard !defaults.bool(forKey: Self.dynamicResolutionResetKey) else { return }
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("screenSharing.dynamicResolution.") {
      defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: Self.dynamicResolutionResetKey)
  }

  public func highDynamicRange(machineId: String) -> Bool {
    defaults.object(forKey: "screenSharing.highDynamicRange.\(machineId)") as? Bool ?? false
  }

  public func setHighDynamicRange(_ enabled: Bool, machineId: String) {
    defaults.set(enabled, forKey: "screenSharing.highDynamicRange.\(machineId)")
  }

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

  public func sharedClipboard(machineId: String) -> Bool {
    defaults.object(forKey: "screenSharing.sharedClipboard.\(machineId)") as? Bool ?? true
  }

  public func setSharedClipboard(_ enabled: Bool, machineId: String) {
    defaults.set(enabled, forKey: "screenSharing.sharedClipboard.\(machineId)")
  }

  public func lastConnected(machineId: String) -> Date? {
    defaults.object(forKey: "screenSharing.lastConnected.\(machineId)") as? Date
  }

  public func setLastConnected(_ date: Date, machineId: String) {
    defaults.set(date, forKey: "screenSharing.lastConnected.\(machineId)")
  }
}
