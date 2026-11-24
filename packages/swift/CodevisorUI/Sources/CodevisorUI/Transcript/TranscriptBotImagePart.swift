import StreamMarkdown
import SwiftUI

public struct TranscriptBotImagePart: View {
  private static let maximumSize = CGSize(width: 320, height: 280)
  private static let placeholderAspectRatio: CGFloat = 16 / 9

  private let source: String
  private let alt: String
  @Environment(\.markdownImageLoader) private var loader
  @Environment(\.markdownLinkAction) private var linkAction
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var image: MarkdownImage?

  public init(source: String, alt: String) {
    self.source = source
    self.alt = alt
  }

  public var body: some View {
    let shape = UserBubbleBackground.shape(for: dynamicTypeSize)
    HStack {
      picture
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: open)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .accessibilityAddTraits([.isImage, .isButton])
        .accessibilityAction(.default, open)
      Spacer(minLength: TranscriptBubbleMetrics.oppositeSideGap)
    }
    .task(id: source) { image = await loader.image(for: source) }
  }

  @ViewBuilder private var picture: some View {
    if let image {
      platformImage(image.image)
        .resizable()
        .aspectRatio(contentMode: .fit)
    } else {
      ZStack {
        Color.bubbleBackground
        Image(systemName: "photo")
          .foregroundStyle(.tertiary)
      }
    }
  }

  @ViewBuilder private var menu: some View {
    if let url, let files = linkAction?.files {
      MarkdownLinkMenuContent(files.menu(url))
    }
  }

  private var url: URL? { URL(string: source) }

  private var size: CGSize {
    boundedAttachmentPreviewSize(
      aspectRatio: aspectRatio, maximumSize: Self.maximumSize, fallbackAspectRatio: Self.placeholderAspectRatio)
  }

  private var aspectRatio: CGFloat? {
    guard let size = image?.image.size, size.width > 0, size.height > 0 else { return nil }
    return size.width / size.height
  }

  private func open() {
    guard let url else { return }
    _ = linkAction?.activate(url, isImage: true)
  }

  private func platformImage(_ image: MarkdownPlatformImage) -> Image {
    #if canImport(AppKit)
      Image(nsImage: image)
    #else
      Image(uiImage: image)
    #endif
  }
}
