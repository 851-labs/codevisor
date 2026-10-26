import SwiftUI

struct ChromiumDownloadsList: View {
  let downloads: ChromiumDownloads

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(downloads.items) { item in
            ChromiumDownloadRow(item: item, downloads: downloads)
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 320)
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      HStack {
        Spacer()
        Button("Clear") { downloads.clearFinished() }
          .disabled(!downloads.items.contains { $0.state != .inProgress })
      }
      .padding(10)
    }
    .frame(width: 340)
  }
}
