import SwiftUI
import StreamMarkdown

public enum PlanDocumentMetrics {
  public static let horizontalPadding: CGFloat = 12
  public static let bottomPadding: CGFloat = 12
  public static let cornerRadius: CGFloat = 8
  public static let borderWidth: CGFloat = 1
  public static let tableBleedLimit: CGFloat = horizontalPadding - borderWidth
}

public struct PlanDocumentView: View {
  let markdown: String

  public init(markdown: String) {
    self.markdown = markdown
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 5) {
        Image(systemName: "list.bullet.clipboard")
          .font(.caption2)
        Text("Proposed Plan")
          .font(.callout.weight(.semibold))
      }
      .foregroundStyle(.secondary)
      StreamingMarkdownView(markdown)
        .markdownContainer(
          padding: PlanDocumentMetrics.horizontalPadding,
          borderWidth: PlanDocumentMetrics.borderWidth
        )
    }
    .padding(PlanDocumentMetrics.horizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackgroundColor))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Proposed plan")
  }
}

public struct PlanDocumentHeaderView: View {
  public init() {}

  public var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "list.bullet.clipboard")
        .font(.caption2)
      Text("Proposed Plan")
        .font(.callout.weight(.semibold))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      PlanDocumentFragmentBackground(
        includesTop: true,
        includesBottom: false
      )
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Proposed plan")
  }
}

public struct PlanDocumentBlockView: View {
  private let blocks: [MarkdownBlock]
  private let documentSource: String
  private let streamID: String
  private let animationGroupID: String
  private let isStreaming: Bool
  private let topSpacing: CGFloat
  private let isLast: Bool
  private let fragmentLayout: MarkdownFragmentLayout?

  public init(
    block: MarkdownBlock,
    documentSource: String,
    streamID: String,
    animationGroupID: String? = nil,
    isStreaming: Bool,
    isLast: Bool,
    fragmentLayout: MarkdownFragmentLayout? = nil,
    topSpacing: CGFloat = 0
  ) {
    blocks = [block]
    self.documentSource = documentSource
    self.streamID = streamID
    self.animationGroupID = animationGroupID ?? streamID
    self.isStreaming = isStreaming
    self.topSpacing = topSpacing
    self.isLast = isLast
    self.fragmentLayout = fragmentLayout
  }

  public init(
    blocks: [MarkdownBlock],
    documentSource: String,
    streamID: String,
    animationGroupID: String? = nil,
    isStreaming: Bool,
    isLast: Bool,
    fragmentLayout: MarkdownFragmentLayout? = nil,
    topSpacing: CGFloat = 0
  ) {
    precondition(!blocks.isEmpty, "Plan Markdown rows must contain at least one block")
    self.blocks = blocks
    self.documentSource = documentSource
    self.streamID = streamID
    self.animationGroupID = animationGroupID ?? streamID
    self.isStreaming = isStreaming
    self.topSpacing = topSpacing
    self.isLast = isLast
    self.fragmentLayout = fragmentLayout
  }

  public var body: some View {
    markdownContent
      .markdownContainer(
        padding: PlanDocumentMetrics.horizontalPadding,
        borderWidth: PlanDocumentMetrics.borderWidth
      )
      .padding(.horizontal, PlanDocumentMetrics.horizontalPadding)
      .padding(.top, topSpacing)
      .padding(.bottom, isLast ? PlanDocumentMetrics.bottomPadding : 0)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        PlanDocumentFragmentBackground(
          includesTop: false,
          includesBottom: isLast
        )
      )
  }

  @ViewBuilder
  private var markdownContent: some View {
    if let fragmentLayout {
      MarkdownFragmentRenderView(
        blocks: blocks,
        documentSource: documentSource,
        streamID: streamID,
        animationGroupID: animationGroupID,
        isStreaming: isStreaming,
        layout: fragmentLayout
      )
    } else {
      MarkdownBlockRenderView(
        blocks: blocks,
        documentSource: documentSource,
        streamID: streamID,
        animationGroupID: animationGroupID,
        isStreaming: isStreaming
      )
    }
  }
}

private struct PlanDocumentFragmentBackground: View {
  let includesTop: Bool
  let includesBottom: Bool

  var body: some View {
    UnevenRoundedRectangle(
      topLeadingRadius: includesTop ? 8 : 0,
      bottomLeadingRadius: includesBottom ? 8 : 0,
      bottomTrailingRadius: includesBottom ? 8 : 0,
      topTrailingRadius: includesTop ? 8 : 0
    )
    .fill(Color.cardBackgroundColor)
    .overlay {
      PlanDocumentFragmentBorder(
        includesTop: includesTop,
        includesBottom: includesBottom
      )
      .stroke(.separator, lineWidth: 1)
    }
  }
}

private struct PlanDocumentFragmentBorder: Shape {
  let includesTop: Bool
  let includesBottom: Bool

  func path(in rect: CGRect) -> Path {
    let radius: CGFloat = 8
    var path = Path()
    if includesTop {
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + radius, y: rect.minY),
        control: CGPoint(x: rect.minX, y: rect.minY)
      )
      path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: rect.minY + radius),
        control: CGPoint(x: rect.maxX, y: rect.minY)
      )
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    } else if includesBottom {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + radius, y: rect.maxY),
        control: CGPoint(x: rect.minX, y: rect.maxY)
      )
      path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
        control: CGPoint(x: rect.maxX, y: rect.maxY)
      )
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    } else {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    }
    return path
  }
}

#Preview {
  PlanDocumentView(
    markdown: """
      # Add goal banner

      1. Extend the wire schema with `SessionGoal`
      2. Map codex `thread/goal/*` in the provider
      3. Render the banner above the composer

      **Verification**: run the dev app and set a goal.
      """
  )
  .padding()
  .frame(width: 560)
}
