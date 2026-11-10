import SwiftUI

struct WorkspaceInspectorFileTransferStatus: View {
  let transfers: WorkspaceFileTransfers

  var body: some View {
    if let label = transfers.latestRunning {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(label).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .modifier(StatusBar())
    } else if let failure = transfers.failure {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(failure).lineLimit(3)
        Spacer(minLength: 0)
        Button("Dismiss", systemImage: "xmark", action: transfers.dismissFailure)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
      .modifier(StatusBar())
    }
  }

  private struct StatusBar: ViewModifier {
    func body(content: Content) -> some View {
      content
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
  }
}
