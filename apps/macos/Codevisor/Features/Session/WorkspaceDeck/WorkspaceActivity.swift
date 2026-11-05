import Observation

@Observable
final class WorkspaceActivity {
  var isActive: Bool

  init(isActive: Bool) {
    self.isActive = isActive
  }
}
