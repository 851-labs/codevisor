import Foundation

public enum ScreenSharingEngine: String, Sendable, CaseIterable {
  case webRTC = "v1"
  case v2

  public static let standard: ScreenSharingEngine = .webRTC
  public static let environmentKey = "CODEVISOR_SCREEN_SHARING_ENGINE"

  public static func selected(
    machineId: String?, preferences: ScreenSharingMachinePreferences = .init(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    if let forced = environment[environmentKey].flatMap(Self.init(rawValue:)) { return forced }
    return machineId.flatMap(preferences.engine(machineId:)) ?? standard
  }
}
