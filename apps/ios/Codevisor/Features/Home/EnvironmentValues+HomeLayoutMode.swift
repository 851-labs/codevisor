import CodevisorCore
import SwiftUI

/// Which Home container is hosting the current screen. Workspace chrome
/// reads this to know whether a native back button exists (stack) or the
/// screen is a split detail, and whether a split tree can be rendered.
extension EnvironmentValues {
  @Entry var homeLayoutMode: HomeLayoutMode = .stack
  /// The split sidebar sits beside the detail, already naming what is on
  /// screen, so the detail drops its title and subtitle to give the content
  /// the height. Collapsed or floating over the detail, it names nothing.
  @Entry var homeSidebarIsTiled: Bool = false
}
