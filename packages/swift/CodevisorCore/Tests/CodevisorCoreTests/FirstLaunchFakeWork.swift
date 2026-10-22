@testable import CodevisorCore

@MainActor
final class FirstLaunchFakeWork: FirstLaunchSetupWork {
  let server = FirstLaunchPendingResult<FirstLaunchServerStart>()
  let harnesses = FirstLaunchPendingResult<[String]>()
  let projects = FirstLaunchPendingResult<Int>()
  let models = FirstLaunchPendingResult<Void>()
  private var projectProgress: (@MainActor (Int) -> Void)?
  private var unreportedProjects: Int?

  func startServer() async -> FirstLaunchServerStart {
    (try? await server.value()) ?? .failed
  }

  func findHarnesses() async throws -> [String] {
    try await harnesses.value()
  }

  func addRecentProjects(progress: @escaping @MainActor (Int) -> Void) async throws -> Int {
    projectProgress = progress
    if let unreportedProjects { progress(unreportedProjects) }
    return try await projects.value()
  }

  func reportProjectsAdded(_ count: Int) {
    guard let projectProgress else {
      unreportedProjects = count
      return
    }
    projectProgress(count)
  }

  func loadModels() async throws {
    try await models.value()
  }
}
