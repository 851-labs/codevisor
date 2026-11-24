import AppKit
import SwiftUI

struct FileDownloadStatus: View {
  let download: FileDownloads.Download

  var body: some View {
    HStack(spacing: 10) {
      FileDownloadStatusIcon(phase: download.phase)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      if case let .finished(url) = download.phase {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          .buttonStyle(.link)
          .font(.callout)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: 420)
    .fixedSize()
    .accessibilityElement(children: .contain)
  }

  private var title: String {
    switch download.phase {
    case .downloading: "Downloading \(download.name)…"
    case .finished: "Downloaded \(download.name)"
    case .failed: "Couldn’t download \(download.name)"
    }
  }

  private var detail: String? {
    switch download.phase {
    case .downloading: nil
    case .finished: "Saved to Downloads"
    case let .failed(message): message
    }
  }
}

private struct FileDownloadStatusIcon: View {
  let phase: FileDownloads.Phase

  var body: some View {
    switch phase {
    case .downloading:
      ProgressView().controlSize(.small)
    case .finished:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
  }
}
