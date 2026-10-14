import CodevisorCore
import SwiftUI

struct UpdateCenterUpkeep: ViewModifier {
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content
      .task {
        guard !AppPreview.isRunning else { return }
        await environment.updateCenter.resumePendingSessionIfNeeded()
        await environment.updateCenter.refresh()
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5 * 60))
          guard !Task.isCancelled else { return }
          environment.machines.ensureBackgroundConnections()
          await environment.updateCenter.backgroundRefresh()
          await environment.configSync.synchronizeAll()
        }
      }
  }
}
