import Foundation

public struct ScreenSharingDiagnosticProfile: Equatable, Sendable {
  public static let environmentKey = "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE"
  static let paced15WorkerName = "paced15-worker"

  public let name: String
  public let playoutDelayMinMs: Int
  public let playoutDelayMaxMs: Int
  public let captureIntervalFPSAtLevel0: Int
  public let renderOnArrival: Bool
  public let maximumDrawableCount: Int
  public let offMainPreparation: Bool

  public static let paced15Worker = ScreenSharingDiagnosticProfile(
    name: paced15WorkerName, playoutDelayMinMs: 1, playoutDelayMaxMs: 15, captureIntervalFPSAtLevel0: 120,
    renderOnArrival: true, maximumDrawableCount: 2, offMainPreparation: true)

  private static let processResult: Result<ScreenSharingDiagnosticProfile?, any Error> = Result {
    try resolve(environment: ProcessInfo.processInfo.environment)
  }

  public static func process() throws -> ScreenSharingDiagnosticProfile? { try processResult.get() }

  public static func resolve(environment: [String: String]) throws -> ScreenSharingDiagnosticProfile? {
    guard let raw = environment[environmentKey], !raw.isEmpty else { return nil }
    guard raw == paced15WorkerName else {
      throw ScreenSharingError.invalid(
        "Unknown \(environmentKey) value \"\(raw)\". Use \"\(paced15WorkerName)\" or unset the variable.")
    }
    return paced15Worker
  }

  public func captureIntervalFPS(adaptiveLevel: Int) -> Int? {
    adaptiveLevel == 0 ? captureIntervalFPSAtLevel0 : nil
  }

  public var playoutExperimentLabel: String {
    "WebRTC-ForcePlayoutDelay min_ms:\(playoutDelayMinMs),max_ms:\(playoutDelayMaxMs)"
  }

  public var fieldTrials: [String: String] {
    ["WebRTC-ForcePlayoutDelay": "min_ms:\(playoutDelayMinMs),max_ms:\(playoutDelayMaxMs)"]
  }

}
