import SwiftUI

struct FolderAccessWaiting: View {
  var body: some View {
    Label {
      Text("Waiting for access…")
    } icon: {
      ProgressView().controlSize(.small)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }
}
