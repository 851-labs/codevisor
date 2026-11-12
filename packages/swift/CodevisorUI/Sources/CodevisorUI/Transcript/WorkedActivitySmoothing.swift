import Foundation
import SwiftUI
import TranscriptKit

struct WorkedActivitySmoothing: ViewModifier {
  let activity: WorkedSectionActivity
  @Binding var smoother: WorkedActivityLabelSmoother

  func body(content: Content) -> some View {
    content
      .onChange(of: activity, initial: true) { _, next in
        smoother.observe(next, now: Date())
      }
      .task(id: smoother.deadline) {
        guard let deadline = smoother.deadline else { return }
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        guard !Task.isCancelled else { return }
        smoother.tick(now: Date())
      }
  }
}
