import SwiftUI

/// Whether the pane is in the active leaf of a split tab. Single-pane
/// screens are always active; inactive leaves hide per-pane floating
/// controls (the terminal's keyboard button) so only one pane offers them.
extension EnvironmentValues {
  @Entry var workspaceLeafIsActive: Bool = true
}
