import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct ScreenSharingConnectionView: View {
  let pane: ScreenSharingPane
  let store: StoreOf<ScreenSharingViewer>

  var body: some View {
    VStack(spacing: 0) {
      if store.isLive, let message = store.lease?.message {
        HStack {
          Text(message).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if store.interactionMode == .control, store.lease?.phase == .viewing {
            Button("Request Control") { store.send(.interactionModeChanged(.control)) }.controlSize(.small)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
      }
      if let message = store.endpoint?.clipboard?.message { banner(message) }
      if store.isLive, let notice = store.hostNotice { banner(notice) }
      ZStack {
        if let endpoint = store.endpoint {
          ScreenSharingNativeView(endpoint: endpoint, holdsPicture: { pane.holdsPicture }).id(store.picturesTaken)
        }
        if !store.isLive { progress }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var progress: some View {
    VStack(spacing: 12) {
      ProgressView().controlSize(.small)
      Text(title)
      if let step = store.stillConnectingStep {
        Text(step).font(.callout).foregroundStyle(.secondary)
      }
      if let notice = store.hostNotice { Text(notice).font(.callout).foregroundStyle(.secondary) }
    }
    .padding(24)
  }

  private var title: String {
    if store.isReconnecting { return "Reconnecting to \(pane.connectionName)…" }
    if store.stillConnectingStep != nil { return "Still connecting…" }
    return "Connecting to \(pane.connectionName)…"
  }

  private func banner(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
  }
}
