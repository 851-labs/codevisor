public enum FirstLaunchStep: Int, CaseIterable, Identifiable, Sendable {
  case server
  case harnesses
  case projects
  case models

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .server: "Starting Codevisor"
    case .harnesses: "Finding your harnesses"
    case .projects: "Adding recent projects"
    case .models: "Loading models"
    }
  }
}
