public enum FirstLaunchStep: Int, CaseIterable, Identifiable, Sendable {
  case localData
  case server
  case harnesses
  case projects
  case models

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .localData: "Preparing local data"
    case .server: "Starting Codevisor"
    case .harnesses: "Finding your harnesses"
    case .projects: "Adding recent projects"
    case .models: "Loading models"
    }
  }
}
