import AppKit
import SwiftUI

struct ChromiumDownloadRow: View {
  let item: ChromiumDownloads.Item
  let downloads: ChromiumDownloads

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
        .resizable()
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.name)
          .lineLimit(1)
          .truncationMode(.middle)
        if let progress = item.progress {
          ProgressView(value: progress)
            .controlSize(.small)
        }
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .accessibilityElement(children: .combine)
      .accessibilityAction(named: "Open") { downloads.open(item) }
      Spacer(minLength: 0)
      if item.state == .inProgress {
        rowButton("Cancel", systemImage: "xmark.circle.fill") { downloads.cancel(item) }
      } else if item.state == .complete {
        rowButton("Show in Finder", systemImage: "magnifyingglass.circle.fill") { downloads.reveal(item) }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .contentShape(.rect)
    .onTapGesture(count: 2) { downloads.open(item) }
  }

  private var status: String {
    let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
    switch item.state {
    case .inProgress:
      guard item.totalBytes > 0 else { return received }
      return "\(received) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))"
    case .complete: return ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
    case .canceled: return "Canceled"
    default: return "Failed"
    }
  }

  private func rowButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}
