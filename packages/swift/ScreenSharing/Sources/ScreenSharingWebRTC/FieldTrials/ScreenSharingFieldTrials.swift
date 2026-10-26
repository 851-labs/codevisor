import Foundation
import ScreenSharing
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
    public func installs(_ other: Selection) -> Bool { trials == other.trials }
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

  public var installed: Selection? {
    condition.lock(); defer { condition.unlock() }
    if case .installed(let selection) = state { return selection }
    return nil
  }

  @discardableResult
  func install(_ selection: Selection) throws -> Selection {
    let inForce = applyOrWaitForFirst(selection)
    guard inForce.installs(selection) else {
      throw ScreenSharingError.invalid(
        "WebRTC field trials are already initialized for \"\(inForce.name)\" in this process and cannot be "
          + "replaced with \"\(selection.name)\". Quit and start a fresh app process to change the selection.")
    }
    return inForce
  }

  @discardableResult
  public func ensureInstalled() -> Selection { applyOrWaitForFirst(.default) }

  @discardableResult
  public func install(profile: ScreenSharingDiagnosticProfile?) throws -> Selection {
    guard let profile else { return installProduct() }
    return try install(profile.trialSelection)
  }

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
