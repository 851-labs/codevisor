import Foundation

public struct ScreenSharingConnectTimes: Sendable, Equatable {
  public private(set) var stage: ScreenSharingConnectStage
  private let began: ContinuousClock.Instant
  private var entered: ContinuousClock.Instant
  private var spent: [ScreenSharingConnectStage: Duration] = [:]

  public init(at now: ContinuousClock.Instant, stage: ScreenSharingConnectStage = .reachingHost) {
    began = now
    entered = now
    self.stage = stage
  }

  public mutating func enter(_ next: ScreenSharingConnectStage, at now: ContinuousClock.Instant) {
    spent[stage, default: .zero] += now - entered
    entered = now
    stage = next
  }

  public func total(at now: ContinuousClock.Instant) -> Duration { now - began }

  public func summary(at now: ContinuousClock.Instant) -> String {
    var spent = spent
    spent[stage, default: .zero] += now - entered
    let parts = ScreenSharingConnectStage.allCases.compactMap { stage in
      spent[stage].map { "\(stage.shortName) \(Self.seconds($0))" }
    }
    return "\(Self.seconds(total(at: now))) s (\(parts.joined(separator: " · ")))"
  }

  private static func seconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.1f", seconds)
  }
}
