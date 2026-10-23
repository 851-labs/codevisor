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

  func startServer() async -> FirstLaunchServerStart {
    (try? await server.value()) ?? .failed
  }

  func isNewInstall() async throws -> Bool {
    try await newInstall.value()
  }

  func findHarnesses() async throws -> [String] {
    try await harnesses.value()
  }

  func addRecentProjects(progress: @escaping @MainActor ([String]) -> Void) async throws -> [String] {
    projectProgress = progress
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
