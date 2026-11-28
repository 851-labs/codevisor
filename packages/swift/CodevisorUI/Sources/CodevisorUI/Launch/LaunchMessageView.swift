import SwiftUI

public struct LaunchMessageView<Actions: View>: View {
  private let title: String
  private let message: String
  private let actions: Actions

  public init(title: String, message: String, @ViewBuilder actions: () -> Actions) {
    self.title = title
    self.message = message
    self.actions = actions()
  }

  public var body: some View {
    CenteredLaunchStack {
      LaunchMark()
      ProgressStepTitle(title: title)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: ProgressStepList.width)
      actions
        .padding(.top, 4)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}
