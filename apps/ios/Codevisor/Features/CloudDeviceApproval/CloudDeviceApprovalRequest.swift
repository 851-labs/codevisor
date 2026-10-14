import CodevisorCore
import Foundation
import Observation

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
    case failed(message: String, retry: Decision?)
  }

  nonisolated let id = UUID()
  let link: CloudDeviceApprovalLink
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
      if decision == .approve { await cloud.refreshMachines() }
    } catch {
      phase = .failed(
        message: Self.message(for: error),
        retry: error is CloudDeviceApprovalError ? nil : decision
      )
    }
  }

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
