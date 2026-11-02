import SwiftUI
import TranscriptKit

struct TranscriptBotFileBubble<Content: View>: View {
  @Environment(\.openFileDocument) private var openFileDocument
  @Environment(\.quickLook) private var quickLook
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let file: PreviewFile
  var showsName = true
  var note: String?
  var naturalWidth: CGFloat?
  @ViewBuilder let content: Content

  var body: some View {
    let shape = UserBubbleBackground.shape(for: dynamicTypeSize)
    VStack(alignment: .leading, spacing: 0) {
      if showsName {
        name
      }
      content
        .allowsHitTesting(false)
      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.bottom, 8)
      }
    }
    .frame(maxWidth: naturalWidth.map { showsName ? max($0, Self.minimumWidth) : $0 }, alignment: .leading)
    .background(Color.bubbleBackground, in: shape)
    .clipShape(shape)
    .contentShape(shape)
    .onTapGesture(perform: preview)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(file.name)
    .accessibilityValue(note ?? "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, preview)
    .attachmentContextMenu(file: file, image: nil, openInNewTab: openInNewTab, quickLook: preview)
  }

  private static var minimumWidth: CGFloat { 180 }

  private var name: some View {
    HStack(spacing: 6) {
      FileIcon(path: file.name, size: 14)
      Text(file.name)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, 10)
    .padding(.top, 8)
  }

  private func openInNewTab() {
    _ = openFileDocument?(FileDocumentLocation.target(for: file))
  }

  private func preview() {
    quickLook?.present(QuickLookItem(file), attachmentStore: attachmentImages)
  }
}
