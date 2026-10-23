@MainActor
public protocol FirstLaunchSetupWork: AnyObject, Sendable {
  func startServer() async -> FirstLaunchServerStart
  func isNewInstall() async throws -> Bool
  func findHarnesses() async throws -> [String]
  func addRecentProjects(progress: @escaping @MainActor ([String]) -> Void) async throws -> [String]
  func loadModels() async throws
}
