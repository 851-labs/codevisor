import SwiftUI

extension EnvironmentValues {
  /// True while THIS app is installing its own update and about to restart.
  /// Injected at the root; the composer reads it to lock its submit action.
  /// A remote machine's server update does not set it: that server drains
  /// and holds its own prompts.
  @Entry var isAppUpdateInProgress: Bool = false
}
