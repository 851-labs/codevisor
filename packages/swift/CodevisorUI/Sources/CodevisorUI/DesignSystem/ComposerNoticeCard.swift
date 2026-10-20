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

private struct NoticeCardText: View {
  let title: String
  let detail: String
  let systemImage: String
  let accent: Color

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct NoticeCardActions: View {
  let actions: [ComposerNoticeCard.Action]
  let fillsWidth: Bool

  var body: some View {
    HStack(spacing: 8) {
      ForEach(actions.indices, id: \.self) { index in
        NoticeCardButton(action: actions[index], fillsWidth: fillsWidth)
      }
    }
  }
}

private struct NoticeCardButton: View {
  let action: ComposerNoticeCard.Action
  let fillsWidth: Bool

  var body: some View {
    if action.emphasis == .primary {
      label.buttonStyle(.borderedProminent)
    } else {
      label.buttonStyle(.bordered).tint(.primary)
    }
  }

  private var label: some View {
    Button(action: action.perform) {
      Text(action.title)
        .lineLimit(1)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
    .controlSize(.regular)
    .fixedSize(horizontal: !fillsWidth, vertical: false)
  }
}
