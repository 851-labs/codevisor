import CodevisorCloud
import Foundation

public enum ScreenSharingEngine: String, Sendable, CaseIterable {
  case webRTC = "v1"
  case v2

  public static let standard: ScreenSharingEngine = .webRTC
  public static let environmentKey = "CODEVISOR_SCREEN_SHARING_ENGINE"

  public static var isChoosable: Bool { CodevisorAppVariant.isDevelopment || CloudReleaseChannel.shared.isAlpha }

  public static func selected(
    machineId: String?, preferences: ScreenSharingMachinePreferences = .init(),
    environment: [String: String] = ProcessInfo.processInfo.environment, choosable: Bool = isChoosable
  ) -> Self {
    if let forced = environment[environmentKey].flatMap(Self.init(rawValue:)) { return forced }
    guard choosable else { return standard }

    return machineId.flatMap(preferences.engine(machineId:)) ?? standard
  }
}
