import AppKit
import CodevisorUI
import SwiftUI

struct FileLightboxBar: View {
  let lightbox: FileLightbox

  private static let height: CGFloat = 46

  var body: some View {
    HStack(spacing: 2) {
      if let file = lightbox.current {
        FileLightboxTitle(name: page?.title ?? file.name)
        Spacer(minLength: 12)
        FileLightboxActions(lightbox: lightbox, file: file, page: page)
      } else {
        Spacer()
      }
      FileLightboxBarButton(title: "Close", systemImage: "xmark", action: lightbox.dismiss)
    }
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .frame(height: Self.height)
  }

  private var page: FilePaneModel? {
    lightbox.current.flatMap(lightbox.page(for:))
  }
}

private struct FileLightboxTitle: View {
  let name: String

  var body: some View {
    HStack(spacing: 8) {
      FileIcon(path: name, size: 16)
      Text(name)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

private struct FileLightboxActions: View {
  let lightbox: FileLightbox
  let file: ViewableFile
  let page: FilePaneModel?

  var body: some View {
    if let opener = lightbox.opener {
      if opener.transfers.download != nil {
        FileLightboxDownloadButton(item: opener.transferItem(for: file))
      }
      FileLightboxMoreMenu(opener: opener, file: file, page: page)
    }
  }
}

private struct FileLightboxMoreMenu: View {
  let opener: FileOpener
  let file: ViewableFile
  let page: FilePaneModel?
  @State private var isHovered = false

  var body: some View {
    Menu {
      if let page, FilePanePreviewToggle.isShown(for: page) {
        Button(sourceTitle(for: page), systemImage: sourceSymbol(for: page)) { page.editor.preview.toggle() }
        Divider()
      }
      FileMenuContent(opener.menu(for: file, omitting: [.preview, .download]))
    } label: {
      FileLightboxBarIcon(systemImage: "ellipsis", isHighlighted: isHovered)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .modifier(FileLightboxBarHover(isHovered: $isHovered))
    .help("More")
    .accessibilityLabel("More")
  }

  private func sourceTitle(for page: FilePaneModel) -> String {
    page.editor.preview ? "Show Source" : "Show Preview"
  }

  private func sourceSymbol(for page: FilePaneModel) -> String {
    page.editor.preview ? "chevron.left.forwardslash.chevron.right" : "eye"
  }
}

private struct FileLightboxDownloadButton: View {
  let item: FileTransferItem
  var downloads: FileDownloads = .shared
  @State private var shown: FileDownloads.Download.ID?

  var body: some View {
    FileLightboxDownloadControl(phase: downloads.phase(of: item.name), start: start)
      .popover(item: shownDownload, arrowEdge: .bottom) { FileDownloadStatus(download: $0) }
      .onChange(of: item.name) { shown = nil }
  }

  private var shownDownload: Binding<FileDownloads.Download?> {
    Binding(
      get: { shown.flatMap(downloads.download) },
      set: { shown = $0?.id })
  }

  private func start() {
    shown = downloads.start(item)?.id
  }
}

private struct FileLightboxDownloadControl: View {
  let phase: FileDownloads.Phase?
  let start: () -> Void

  var body: some View {
    switch phase {
    case .downloading:
      ProgressView()
        .controlSize(.small)
        .frame(width: FileLightboxBarIcon.side, height: FileLightboxBarIcon.side)
        .help("Downloading…")
        .accessibilityLabel("Downloading")
    case let .finished(url):
      FileLightboxBarButton(title: "Show in Finder", systemImage: "checkmark") {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    case .failed, nil:
      FileLightboxBarButton(title: "Download", systemImage: FileTransfers.downloadSymbol, action: start)
    }
  }
}

private struct FileLightboxBarButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      FileLightboxBarIcon(systemImage: systemImage, isHighlighted: isHovered)
    }
    .buttonStyle(.plain)
    .modifier(FileLightboxBarHover(isHovered: $isHovered))
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct FileLightboxBarIcon: View {
  let systemImage: String
  let isHighlighted: Bool

  static let side: CGFloat = 30

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(isHighlighted ? .primary : .secondary)
      .frame(width: Self.side, height: Self.side)
      .contentShape(Rectangle())
  }
}

private struct FileLightboxBarHover: ViewModifier {
  @Binding var isHovered: Bool

  func body(content: Content) -> some View {
    content
      .background(.quaternary.opacity(isHovered ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
      .onHover { isHovered = $0 }
  }
}
