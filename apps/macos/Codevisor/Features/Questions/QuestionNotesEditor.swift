import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionNotesEditor: View {
  let draft: QuestionDraft
  let question: QuestionSpec
  let placeholder: String
  let focusTargets: QuestionPickerFocusTargets
  let onSubmit: () -> Void

  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var height: CGFloat = 24

  var body: some View {
    ZStack(alignment: .topLeading) {
      ChatInputEditor(
        text: Binding(get: { draft.note(for: question) }, set: { draft.setNote($0, for: question) }),
        calculatedHeight: $height,
        minHeight: 24,
        maxHeight: 120,
        onSubmit: onSubmit,
        onKeyCommand: dismissToPicker,
        onTextViewReady: focusTargets.attachNotesEditor
      )
      .frame(height: height)
      if draft.note(for: question).isEmpty {
        Text(placeholder)
          .foregroundStyle(.tertiary)
          .padding(.top, 6)
          .allowsHitTesting(false)
      }
    }
    .onChange(of: height) { _, _ in invalidateRowMeasurement?() }
  }

  private func dismissToPicker(_ command: ComposerKeyCommand) -> Bool {
    guard command == .dismissSelection else { return false }
    focusTargets.focusPicker()
    return true
  }
}
