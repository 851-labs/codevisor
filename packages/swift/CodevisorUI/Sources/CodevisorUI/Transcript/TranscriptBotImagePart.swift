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
        .onTapGesture(perform: quickLook)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .accessibilityAddTraits([.isImage, .isButton])
        .accessibilityAction(.default, quickLook)
      Spacer(minLength: 40)
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
    if let url, let images = linkAction?.images {
      if let addToChat = images.addToChat {
        Button {
          addToChat(url)
        } label: {
          menuLabel("Add to Chat", "text.bubble")
        }
        Divider()
      }
      Button {
        _ = images.open(url)
      } label: {
        menuLabel("Quick Look", "eye")
      }
      if let openInNewTab = images.openInNewTab {
        Button {
          openInNewTab(url)
        } label: {
          menuLabel("Open in New Tab", "plus.rectangle.on.rectangle")
        }
      }
      if let copy = images.copy {
        Button {
          copy(url)
        } label: {
          menuLabel("Copy", "doc.on.doc")
        }
      }
    }
  }

  private func menuLabel(_ title: String, _ systemImage: String) -> some View {
    Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
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

  private func quickLook() {
    guard let url, let images = linkAction?.images else { return }
    _ = images.open(url)
  }

  private func platformImage(_ image: MarkdownPlatformImage) -> Image {
    #if canImport(AppKit)
      Image(nsImage: image)
    #else
      Image(uiImage: image)
    #endif
  }
}
