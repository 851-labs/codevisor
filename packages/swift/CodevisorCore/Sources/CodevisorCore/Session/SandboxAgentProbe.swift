import CodevisorClient

enum SandboxAgentProbe: Equatable {
  case ready(ServerHarnessCapability)
  case installing(String)
  case waiting(String)

  init(_ capability: ServerHarnessCapability) {
    let harness = capability.harness
    if harness.enabled, harness.isReady {
      self = .ready(capability)
    } else if Self.isInstalling(harness) {
      self = .installing(Self.waitingReason(harness))
    } else {
      self = .waiting(Self.waitingReason(harness))
    }
  }

  var detail: String? {
    switch self {
    case .ready: nil
    case let .installing(detail), let .waiting(detail): detail
    }
  }

  private static func isInstalling(_ harness: ServerHarness) -> Bool {
    guard !harness.isReady else { return false }
    switch harness.lifecycle?.phase {
    case "installing", "updating": return true
    default: return false
    }
  }

  private static func waitingReason(_ harness: ServerHarness) -> String {
    guard harness.isReady else {
      return "Waiting for \(harness.name) to install (\(harness.readiness.detail ?? harness.readiness.state))"
    }
    switch harness.auth?.resolvedState {
    case .unauthenticated, .expired: return "\(harness.name) isn't signed in on this machine"
    case .checking, nil: return "Checking \(harness.name)'s sign-in"
    default: return "\(harness.name) isn't enabled on this machine"
    }
  }
}
