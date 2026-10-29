import SwiftUI

public struct QuestionOptionTitle: View {
  let option: QuestionOptionLabel

  public init(_ label: String) {
    option = QuestionOptionLabel(label)
  }

  public var body: some View {
    if option.isRecommended {
      Text("\(Text(option.title))  \(recommendedTag)")
    } else {
      Text(option.title)
    }
  }

  private var recommendedTag: Text {
    Text("Recommended")
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
  }
}
