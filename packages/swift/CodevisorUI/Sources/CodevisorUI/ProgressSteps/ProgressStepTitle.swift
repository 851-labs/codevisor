import SwiftUI

public struct ProgressStepTitle: View {
  let title: String

  public init(title: String) {
    self.title = title
  }

  public var body: some View {
    Text(title)
      .font(.title2.weight(.semibold))
      .multilineTextAlignment(.center)
      .contentTransition(.opacity)
      .animation(.smooth(duration: 0.3), value: title)
  }
}
