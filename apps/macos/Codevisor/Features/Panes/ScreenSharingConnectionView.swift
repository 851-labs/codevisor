import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct ScreenSharingConnectionView: View {
  let pane: ScreenSharingPane
  let store: StoreOf<ScreenSharingViewer>

  var body: some View {
    VStack(spacing: 0) {
      if store.isLive, let message = store.control?.message {
        HStack {
          Text(message).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if store.canAskForControl {
            Button("Request Control") { store.send(.controlTaken) }.controlSize(.small)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
      }
      if let message = store.endpoint?.clipboard?.message { banner(message) }
      if store.isLive, let notice = store.hostNotice { banner(notice) }
      if let line = store.displaySwitchLine {
        ScreenSharingDisplaySwitchBanner(line: line) { store.send(.displaySwitchDismissed) }
      }
      ZStack {
        if let endpoint = store.endpoint {
          ScreenSharingNativeView(pane: pane, onClick: takeControl).id(endpoint.id)
        }
        if !store.isLive {
          ScreenSharingStatusView(content: progress, size: .pane) { _ in }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var takeControl: (() -> Void)? {
    guard store.isLive, store.control == nil, store.interactionMode == .control, pane.role != .watcher else {
      return nil
    }

    return {
      store.send(.controlTaken)
      pane.onFocusChanged?(true)
    }
  }

  private var progress: ScreenSharingStatusView.Content {
    .progress(title: title, details: [store.stillConnectingStep, store.hostNotice].compactMap(\.self))
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
