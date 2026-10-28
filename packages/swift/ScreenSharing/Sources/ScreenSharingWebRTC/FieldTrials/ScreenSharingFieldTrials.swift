import Foundation
import WebRTCProcessFieldTrials

public final class ScreenSharingFieldTrials: @unchecked Sendable {
  public struct Selection: Equatable, Sendable {
    public let name: String
    public let trials: [String: String]
    public init(name: String, trials: [String: String]) { self.name = name; self.trials = trials }
    public static let `default` = Selection(name: "default", trials: [:])
    public static let product = Selection(
      name: "product",
      trials: [
        "WebRTC-ForcePlayoutDelay": "min_ms:15,max_ms:80", "WebRTC-Video-Pacing": "factor:10",
        "WebRTC-FrameDropper": "Disabled",
      ])
    public var playoutExperimentLabel: String? {
      trials["WebRTC-ForcePlayoutDelay"].map { "WebRTC-ForcePlayoutDelay \($0)" }
    }
  }

  private enum State {
    case none
    case applying
    case installed(Selection)
  }

  private let apply: @Sendable ([String: String]) -> Void
  private let condition = NSCondition()
  private var state: State = .none
  var onWaitingForApply: (@Sendable () -> Void)?

  public init(apply: @escaping @Sendable ([String: String]) -> Void) { self.apply = apply }

  public static let process = ScreenSharingFieldTrials(apply: { trials in
    if !trials.isEmpty { CodevisorInstallWebRTCProcessFieldTrials(trials) }
  })

  @discardableResult
  public func ensureInstalled() -> Selection { applyOrWaitForFirst(.default) }

  @discardableResult
  public func installProduct() -> Selection { applyOrWaitForFirst(.product) }

  private func applyOrWaitForFirst(_ requested: Selection) -> Selection {
    condition.lock()
    while true {
      switch state {
      case .none:
        state = .applying
        condition.unlock()
        apply(requested.trials)
        condition.lock()
        state = .installed(requested)
        condition.broadcast()
        condition.unlock()
        return requested
      case .applying:
        let observer = onWaitingForApply
        if let observer {
          condition.unlock()
          observer()
          condition.lock()
          if case .applying = state {} else { continue }
        }
        condition.wait()
      case .installed(let existing):
        condition.unlock()
        return existing
      }
    }
  }
}
