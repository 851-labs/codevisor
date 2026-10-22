import Foundation

extension ProjectMachineSetup {
  public static let retryTitle = "Try Again"

  public struct Screen: Equatable, Sendable {
    public let symbol: String
    public let title: String
    public let message: String
    public var caution: String?
  }

  public func screen(showing plan: Plan?) -> Screen {
    switch phase {
    case let .signingIn(_, model):
      let provider = model.provider?.displayName ?? "Git"
      return Screen(
        symbol: "person.badge.key",
        title: "Sign In to \(provider)",
        message: "\(model.machineName) needs to sign in to \(provider) to continue."
      )
    case let .failed(_, failure) where failure.isMissingRepository:
      return Screen(symbol: "questionmark.folder", title: "Repository not found", message: failure.message)
    case let .unavailable(project, machine):
      return Screen(
        symbol: "folder",
        title: "Clone \(project) to \(machine)?",
        message: "\(project) has no remote, and the machine it's on is offline."
      )
    default:
      guard let plan else { return Screen(symbol: "folder", title: "", message: "") }
      let name = plan.projectName
      let machine = plan.targetMachineName
      if plan.needsRemote {
        return Screen(
          symbol: "square.and.arrow.up",
          title: "Add a remote for \(name)",
          message: "To use \(name) on \(machine), it needs a git remote to clone from.",
          caution: failureMessage
        )
      }
      return Screen(
        symbol: "square.and.arrow.down",
        title: "Clone \(name) to \(machine)?",
        message: "\(name) isn't on \(machine) yet. We'll clone it there so you can use it.",
        caution: failureMessage
      )
    }
  }

  private var failureMessage: String? {
    if case let .failed(_, failure) = phase { return failure.message }
    return nil
  }
}

extension ProjectMachineSetup.Plan {
  public var remoteProvider: GitHostProvider { provider ?? .github }
  public var pushTitle: String { "Push to Remote" }
  public var cloneTitle: String { "Clone to \(targetMachineName)" }
  public var createRepoTitle: String { "Create Repo on \(remoteProvider.displayName)" }
  public var repoPlaceholder: String { "https://\(remoteProvider.defaultHost)/you/\(projectName)" }
}
