import AppKit
import SwiftUI

struct ChromiumDownloadsButton: View {
  let downloads: ChromiumDownloads
  @State private var presented = false

  var body: some View {
    if !downloads.items.isEmpty {
      Button {
        presented.toggle()
      } label: {
        Image(systemName: "arrow.down.circle")
          .overlay {
            if let progress = downloads.activeProgress {
              Circle()
                .trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-1)
            }
          }
          .frame(width: 34, height: 32)
      }
      .buttonStyle(.plain)
      .help("Downloads")
      .accessibilityLabel("Downloads")
      .popover(isPresented: $presented, arrowEdge: .bottom) {
        ChromiumDownloadsList(downloads: downloads)
      }
      .onChange(of: downloads.wantsPresentation, initial: true) { _, wanted in
        guard wanted else { return }
        presented = true
        downloads.presented()
      }
    }
  }
}
