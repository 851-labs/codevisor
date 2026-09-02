import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Covers generic questions while their answer is submitted. Browser choice
/// keeps its card visible and reports progress on its explicit Continue action.
struct QuestionResolutionOverlay: View {
    @Bindable var controller: SessionController

    var body: some View {
        if shouldShow {
            RoundedRectangle(cornerRadius: ComposerGlassStyle.composerCornerRadius)
                .fill(Color(.systemGroupedBackground).opacity(0.72))
                .overlay {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Submitting response…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Submitting response")
        }
    }

    private var shouldShow: Bool {
        guard let request = controller.activeQuestion,
            controller.isResolvingQuestion
        else {
            return false
        }
        return !request.questions.contains { $0.presentation == .browserChoice }
    }
}
