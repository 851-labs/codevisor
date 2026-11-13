public enum FirstLaunchStep: Int, CaseIterable, Identifiable, Sendable {
  case harnesses
  case projects
  case models

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .harnesses: "Finding your harnesses"
    case .projects: "Adding recent projects"
    case .models: "Loading models"
    }
  }
}
