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
}
