import SwiftUI

struct GitInstallStatus: View {
  let install: GitInstallProgress

  var body: some View {
    switch install {
    case .notStarted, .opening:
      EmptyView()
    case .waiting:
      Label {
        Text("Waiting for installation…")
      } icon: {
        ProgressView().controlSize(.small)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    case let .failed(message):
      Text(message)
        .font(.callout)
        .foregroundStyle(.red)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
