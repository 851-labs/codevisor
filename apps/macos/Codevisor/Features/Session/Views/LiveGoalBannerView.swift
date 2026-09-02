import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

/// Reads SessionModel.goal directly so activity/lifecycle snapshots invalidate
/// this small subtree. Going through SessionController.goal only observed the
/// stable model reference and left the first goal snapshot frozen on screen.
struct LiveGoalBannerView: View {
  @Bindable var controller: SessionController
  @Bindable var model: SessionModel
  let glassNamespace: Namespace.ID

  var body: some View {
    if let goal = model.goal {
      GoalBannerView(
        controller: controller,
        goal: goal,
        glassNamespace: glassNamespace
      )
    }
  }
}
