import Observation

@MainActor
@Observable
public final class WorkspaceActivity {
  public var isActive: Bool

  public init(isActive: Bool) {
    self.isActive = isActive
  }
}
