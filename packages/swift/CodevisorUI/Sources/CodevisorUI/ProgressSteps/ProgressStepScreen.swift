import SwiftUI

public struct ProgressStepScreen<Actions: View>: View {
  private let title: String
  private let steps: [ProgressStep]
  private let note: String?
  private let actions: Actions

  public init(
    title: String,
    steps: [ProgressStep],
    note: String? = nil,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.steps = steps
    self.note = note
    self.actions = actions()
  }

  public var body: some View {
    IconAnchoredStack {
      CodevisorAppIconView(size: 72)
      ProgressStepTitle(title: title)
      ProgressStepCard(steps: steps)
      if let note {
        ProgressStepNote(text: note)
      }
      actions
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

extension ProgressStepScreen where Actions == EmptyView {
  public init(title: String, steps: [ProgressStep], note: String? = nil) {
    self.init(title: title, steps: steps, note: note) { EmptyView() }
  }
}
