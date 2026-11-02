import SwiftUI

public struct ProgressStepList: View {
  private let steps: [ProgressStep]

  public static let width: CGFloat = 440

  public init(steps: [ProgressStep]) {
    self.steps = steps
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(steps) { step in
        ProgressStepRow(step: step)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: Self.width)
  }
}
