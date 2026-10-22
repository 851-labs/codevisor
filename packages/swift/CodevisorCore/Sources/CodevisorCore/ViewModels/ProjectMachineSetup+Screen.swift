import Foundation

extension ProjectMachineSetup {
  public static let retryTitle = "Try Again"
  public static let setUpTitle = "Set Up"

  public struct Screen: Equatable, Sendable {
    public let symbol: SheetSymbol
    public let title: String
    public let message: String
    public var caution: String?
  }

  public func screen(showing plan: Plan?) -> Screen {
    switch phase {
    case let .signingIn(plan, model):
      return signInScreen(plan, model)
    case let .failed(plan, failure) where failure.needsHostSignIn:
      let host = GitHost(name: failure.host ?? "your git host")
      return Screen(
        symbol: host.logo,
        title: "Sign In to \(host.displayName)",
        message: "Sign in to \(host.displayName) on \(plan.targetMachineName), then try again."
      )
    case let .failed(_, failure) where failure.isMissingRepository:
      return Screen(symbol: .system("questionmark.folder"), title: "Repository not found", message: failure.message)
    case let .unavailable(project, machine):
      return Screen(
        symbol: .system("folder"),
        title: "Clone \(project) to \(machine)?",
        message: "\(project) has no remote, and the machine it's on is offline."
      )
    default:
      guard let plan else { return Screen(symbol: .system("folder"), title: "", message: "") }
      let name = plan.projectName
      let machine = plan.targetMachineName
      if plan.needsRemote {
        return Screen(
          symbol: .system("square.and.arrow.up"),
          title: "Add a remote for \(name)",
          message: "To use \(name) on \(machine), it needs a git remote to clone from.",
          caution: failureMessage
        )
      }
      return Screen(
        symbol: .system("square.and.arrow.down"),
        title: "Clone \(name) to \(machine)?",
        message: "\(name) isn't on \(machine) yet. We'll clone it there so you can use it.",
        caution: failureMessage
      )
    }
  }

  public var activity: String? {
    switch phase {
    case .running, .finished: progress.line
    case let .signingIn(_, model): model.activity
    default: nil
    }
  }

  private func signInScreen(_ plan: Plan, _ model: GitSignInModel) -> Screen {
    let provider = model.provider ?? plan.remoteProvider
    let name = provider.displayName
    let machine = model.machineName
    let message =
      if case .confirmingSetup = model.step {
        "To clone \(plan.projectName) on \(machine), you need to sign in to \(name). Set up \(name) on \(machine)?"
      } else {
        "\(machine) needs to sign in to \(name) to continue."
      }
    return Screen(symbol: provider.logo, title: "Sign In to \(name)", message: message)
  }

  private var failureMessage: String? {
    if case let .failed(_, failure) = phase { return failure.message }
    return nil
  }
}

extension ProjectMachineSetup.SetupProgress {
  public var line: String {
    guard let fraction else { return label }
    return "\(label) \(Int((fraction * 100).rounded()))%"
  }
}

extension ProjectMachineSetup.Plan {
  public var remoteProvider: GitHostProvider { provider ?? .github }
  public var pushTitle: String { "Push to Remote" }
  public var cloneTitle: String { "Clone to \(targetMachineName)" }
  public var createRepoTitle: String { "Create Repo on \(remoteProvider.displayName)" }
  public var repoPlaceholder: String { "https://\(remoteProvider.defaultHost)/you/\(projectName)" }
}
