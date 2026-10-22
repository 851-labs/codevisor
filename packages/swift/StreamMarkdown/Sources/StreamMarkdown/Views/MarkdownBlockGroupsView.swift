import SwiftUI

public struct MarkdownBlockGroupsView: View {
  private let blocks: [MarkdownBlock]
  private let groups: [[MarkdownBlock]]
  private let documentSource: String
  private let streamID: String
  @Environment(\.markdownTheme) private var theme

  public init(blocks: [MarkdownBlock], documentSource: String, streamID: String) {
    self.blocks = blocks
    groups = Self.groups(blocks)
    self.documentSource = documentSource
    self.streamID = streamID
  }

  public var body: some View {
    #if canImport(AppKit)
      if SettledMarkdownRepresentable.canRender(blocks) {
        SettledMarkdownRepresentable(blocks: blocks, streamID: streamID)
      } else {
        groupedBlocks
      }
    #else
      groupedBlocks
    #endif
  }

  private var groupedBlocks: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(groups.indices, id: \.self) { index in
        MarkdownBlockRenderView(
          blocks: groups[index],
          documentSource: documentSource,
          streamID: "\(streamID).\(index)",
          isStreaming: false
        )
        .padding(.top, index == 0 ? 0 : gap(before: index))
      }
    }
  }

  private func gap(before index: Int) -> CGFloat {
    guard let previous = groups[index - 1].last?.role, let next = groups[index].first?.role else { return 0 }
    return theme.blockGap(after: previous, before: next)
  }

  static func groups(_ blocks: [MarkdownBlock]) -> [[MarkdownBlock]] {
    var groups: [[MarkdownBlock]] = []
    var run: [MarkdownBlock] = []
    for block in blocks {
      if block.isTextRunCompatible {
        run.append(block)
        continue
      }
      if !run.isEmpty { groups.append(run) }
      run = []
      groups.append([block])
    }
    if !run.isEmpty { groups.append(run) }
    return groups
  }
}
