import CodevisorCoreMac
import SwiftUI

struct ScreenSharingMirrorPane: View {
  let endpoint: ScreenSharingViewerEndpoint?
  let connectionName: String
  let onTakeControl: (() -> Void)?

  var body: some View {
    ZStack {
      if let endpoint {
        ScreenSharingMirrorHost(endpoint: endpoint)
          .id(endpoint.id)
      } else {
        connecting
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if let onTakeControl, endpoint != nil {
        takeControlButton(onTakeControl)
      }
    }
  }

  private var connecting: some View {
    VStack(spacing: 12) {
      ProgressView().controlSize(.small)
      Text("Connecting to \(connectionName)…").foregroundStyle(.secondary)
    }
    .padding(24)
  }

  private func takeControlButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label("Take Control", systemImage: "cursorarrow.click.2")
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(16)
    .help("Control \(connectionName) here instead of where it is controlled now")
  }
}
