import SwiftUI

public struct ProgressStepCard: View {
  private let steps: [ProgressStep]

  public static let cornerRadius: CGFloat = 22

  public init(steps: [ProgressStep]) {
    self.steps = steps
  }

  public var body: some View {
    ProgressStepList(steps: steps)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
  }
}
