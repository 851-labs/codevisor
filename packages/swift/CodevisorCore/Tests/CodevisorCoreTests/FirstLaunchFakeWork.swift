import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
final class FirstLaunchFakeWork: FirstLaunchSetupWork {
  let server = FirstLaunchPendingResult<FirstLaunchServerStart>()
  let newInstall = FirstLaunchPendingResult<Bool>()
  let harnesses = FirstLaunchPendingResult<[String]>()
  let projects = FirstLaunchPendingResult<[String]>()
  let models = FirstLaunchPendingResult<Void>()
  private var projectProgress: (@MainActor ([String]) -> Void)?
  private var unreportedProjects: [String]?

  let serverStartRequested = TestSignal()
  let projectsRequested = TestSignal()
  private var reportWaitingOnUser: (@MainActor (Bool) -> Void)?

  func startServer(waitingOnUser: @escaping @MainActor (Bool) -> Void) async -> FirstLaunchServerStart {
    reportWaitingOnUser = waitingOnUser
    serverStartRequested.signal()
    return (try? await server.value()) ?? .failed
  }

  func waitOnUser() {
    reportWaitingOnUser?(true)
  }

  func isNewInstall() async throws -> Bool {
    try await newInstall.value()
  }

  func findHarnesses() async throws -> [String] {
    try await harnesses.value()
  }

  func addRecentProjects(
    progress: @escaping @MainActor ([String]) -> Void,
    waitingOnUser: @escaping @MainActor (Bool) -> Void
  ) async throws -> [String] {
    projectProgress = progress
    reportWaitingOnUser = waitingOnUser
    projectsRequested.signal()
    if let unreportedProjects { progress(unreportedProjects) }
    return try await projects.value()
  }

  func reportProjectsAdded(_ names: [String]) {
    guard let projectProgress else {
      unreportedProjects = names
      return
    }
    projectProgress(names)
  }

  func loadModels() async throws {
    try await models.value()
  }
}
