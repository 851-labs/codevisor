import CodevisorCore
import Foundation
import Observation

/// One scanned `codevisor auth login` QR code, from routing until its sheet
/// is dismissed. The state lives here rather than in the sheet so the flow
/// survives the sheet being re-hosted (the onboarding cover dismissing
/// underneath it) without losing a result the user hasn't seen yet.
@MainActor
@Observable
final class CloudDeviceApprovalRequest: Identifiable {
  enum Decision: Equatable {
    case approve
    case deny
  }

  enum Phase: Equatable {
    case ready
    case sending(Decision)
    case approved
    case denied
    /// `retry` is the decision worth sending again, nil when the code
    /// itself is unusable (expired, already used, another cloud).
    case failed(message: String, retry: Decision?)
  }

  nonisolated let id = UUID()
  let link: CloudDeviceApprovalLink
  /// Whether the onboarding cover was on screen when the link arrived. The
  /// sheet presents from whichever context was visible, and Home keeps the
  /// cover up until the sheet is dismissed so its host never disappears
  /// mid-approval.
  let presentsOverOnboarding: Bool
  private(set) var phase: Phase = .ready

  init(link: CloudDeviceApprovalLink, presentsOverOnboarding: Bool) {
    self.link = link
    self.presentsOverOnboarding = presentsOverOnboarding
  }

  var isSending: Bool {
    if case .sending = phase { return true }
    return false
  }

  func send(_ decision: Decision, cloud: CloudAccountController) async {
    guard !isSending else { return }
    phase = .sending(decision)
    do {
      switch decision {
      case .approve: try await cloud.approveDevice(link)
      case .deny: try await cloud.denyDevice(link)
      }
      phase = decision == .approve ? .approved : .denied
      // The machine registers itself once its CLI sees the approval; this
      // refresh (and the hub's presence push) brings it into the list.
      if decision == .approve { await cloud.refreshMachines() }
    } catch {
      phase = .failed(
        message: Self.message(for: error),
        retry: error is CloudDeviceApprovalError ? nil : decision
      )
    }
  }

  /// A failure from before sign-in (or from an expired session) says
  /// nothing about the new session; start over from the approval step.
  func resetFailure() {
    if case .failed = phase { phase = .ready }
  }

  private static func message(for error: any Error) -> String {
    if error is URLError {
      return "Couldn't reach Codevisor Cloud. Check your connection and try again."
    }
    return error.localizedDescription
  }
}
