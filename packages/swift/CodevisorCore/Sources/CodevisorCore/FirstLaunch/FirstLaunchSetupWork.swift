@MainActor
public protocol FirstLaunchSetupWork: AnyObject, Sendable {
  func startServer() async -> FirstLaunchServerStart
  func findHarnesses() async throws -> [String]
  func addRecentProjects(progress: @escaping @MainActor (Int) -> Void) async throws -> Int
  func loadModels() async throws
}
