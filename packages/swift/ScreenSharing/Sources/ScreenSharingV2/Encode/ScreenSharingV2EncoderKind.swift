import Foundation

public enum ScreenSharingV2EncoderKind: String, Sendable, CaseIterable {
  case videoToolbox = "vt"
  case videoProcessing = "vcp"

  public static let environmentKey = "CODEVISOR_SCREEN_SHARING_V2_ENCODER"

  public static func configured(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
    environment[environmentKey].flatMap(Self.init(rawValue:)) ?? .videoProcessing
  }

  public static func forViewer(
    chroma: String?, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    chroma == ScreenSharingV2Chroma.subsampled.rawValue ? .videoToolbox : configured(environment)
  }
}
