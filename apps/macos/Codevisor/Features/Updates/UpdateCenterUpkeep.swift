import CodevisorCore
import SwiftUI

/// The fleet update upkeep cadence. Its own modifier (like the deeplink
/// handlers) so ContentView's already-large chain stays within
/// type-checker and size budgets. The update UI itself lives in
/// Settings › Updates; nothing here presents anything.
struct UpdateCenterUpkeep: ViewModifier {
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content
      .task {
        // Fleet-wide upkeep, deliberately NOT keyed to the selected
        // machine: every machine keeps its stream and release state
        // current, so a release cut (or work finishing) on an
        // unselected machine is still noticed. One initial sweep
        // populates the sidebar footer's count, then the cadence.
        guard !AppPreview.isRunning else { return }
        // A pending update-all session (the app update restarted
        // this client, or a run died) finishes first.
        await environment.updateCenter.resumePendingSessionIfNeeded()
        await environment.updateCenter.refresh()
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5 * 60))
          guard !Task.isCancelled else { return }
          environment.machines.ensureBackgroundConnections()
          await environment.machines.refreshServerUpdates()
          await environment.updateCenter.refresh()
          await environment.configSync.synchronizeAll()
        }
      }
  }
}
