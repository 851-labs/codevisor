import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

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
