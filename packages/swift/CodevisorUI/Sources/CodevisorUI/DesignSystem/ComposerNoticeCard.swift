import SwiftUI

public struct ComposerNoticeCard: View {
  public struct Action {
    public enum Emphasis {
      case primary
      case quiet
    }

    let title: String
    let emphasis: Emphasis
    let perform: () -> Void

    public init(_ title: String, emphasis: Emphasis, perform: @escaping () -> Void) {
      self.title = title
      self.emphasis = emphasis
      self.perform = perform
    }
  }

  private var cardStyle = ComposerCardStyle()
  @Environment(\.pixelLength) private var pixelLength
  private let title: String
  private let detail: String
  private let systemImage: String
  private let accent: Color
  private let actions: [Action]

  public init(
    title: String,
    detail: String,
    systemImage: String,
    accent: Color,
    actions: [Action]
  ) {
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.accent = accent
    self.actions = actions
  }

  public var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        NoticeCardText(title: title, detail: detail, systemImage: systemImage, accent: accent)
        Spacer(minLength: 0)
        NoticeCardActions(actions: actions, fillsWidth: false)
      }
      VStack(alignment: .leading, spacing: 12) {
        NoticeCardText(title: title, detail: detail, systemImage: systemImage, accent: accent)
        NoticeCardActions(actions: actions, fillsWidth: true)
      }
    }
    .padding(ComposerCardStyle.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .containerShape(cardStyle.containerShape)
    .buttonBorderShape(cardStyle.buttonBorderShape)
    .background {
      ZStack {
        cardStyle.shape.fill(Color.windowBackgroundColor)
        cardStyle.shape.fill(Color.cardBackgroundColor)
        cardStyle.insetShape(by: pixelLength / 2).stroke(Color.separatorColor, lineWidth: pixelLength)
      }
    }
    .accessibilityElement(children: .contain)
  }
}
