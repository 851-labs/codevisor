@testable import CodevisorCore

@MainActor
final class FirstLaunchFakeWork: FirstLaunchSetupWork {
  let server = FirstLaunchPendingResult<FirstLaunchServerStart>()
  let harnesses = FirstLaunchPendingResult<[String]>()
  let projects = FirstLaunchPendingResult<Int>()
  let models = FirstLaunchPendingResult<Void>()

  func startServer() async -> FirstLaunchServerStart {
    (try? await server.value()) ?? .failed
  }

  func findHarnesses() async throws -> [String] {
    try await harnesses.value()
  }

  func addRecentProjects() async throws -> Int {
    try await projects.value()
  }

  func loadModels() async throws {
    try await models.value()
  }
}
