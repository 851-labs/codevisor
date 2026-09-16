import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

/// Window toolbar controls borrow the selected pane's store; the pane owns
/// the connection and control state across toolbar and menu updates.
/// Controls that need a capability the connected backend lacks are not shown.
struct ScreenSharingToolbar: ToolbarContent {
  @Bindable var store: StoreOf<ScreenSharingViewer>

  var body: some ToolbarContent {
    ToolbarItem(id: "screenSharing.mode", placement: .principal) {
      if store.endpoint?.supportsControl != false { controlActions }
    }
    ToolbarItem(id: "screenSharing.size", placement: .primaryAction) {
      Picker("Size", selection: $store.preferences.fitToWindow.sending(\.fitToWindowChanged)) {
        Text("Fit").tag(true)
        Text("Actual Size").tag(false)
      }
      .labelsHidden().frame(width: 110)
    }
    ToolbarItem(id: "screenSharing.clipboard", placement: .primaryAction) {
      if store.endpoint?.supportsClipboard != false {
        Menu {
          Group {
            Button("Send Clipboard to Mac") { store.endpoint?.clipboard?.sendLocalText() }
            Button("Get Clipboard from Mac") { store.endpoint?.clipboard?.getRemoteText() }
          }
          .disabled(store.endpoint?.clipboard?.available != true || store.endpoint?.clipboard?.busy == true)
        } label: {
          Image(systemName: "doc.on.clipboard")
        }
        .accessibilityLabel("Clipboard")
        .help("Transfer plain text between clipboards")
      }
    }
    ToolbarItem(id: "screenSharing.details", placement: .primaryAction) {
      ScreenSharingDetailsButton(store: store).id(ObjectIdentifier(store))
    }
  }

  private var controlActions: some View {
    Picker("Interaction mode", selection: $store.interactionMode.sending(\.interactionModeChanged)) {
      Text("View").tag(ScreenSharingViewer.InteractionMode.view)
      Text("Control").tag(ScreenSharingViewer.InteractionMode.control)
    }
    .pickerStyle(.segmented).labelsHidden().fixedSize()
    .help("Send mouse, keyboard and app shortcuts to this Mac. Control–Option–Escape returns to viewing.")
  }

}

private struct ScreenSharingDetailsButton: View {
  let store: StoreOf<ScreenSharingViewer>
  @State private var showDiagnostics = false

  var body: some View {
    Button {
      showDiagnostics.toggle()
    } label: {
      Image(systemName: "info.circle")
    }
    .accessibilityLabel("Connection Details")
    .help("Connection Details")
    .popover(isPresented: $showDiagnostics) { details.padding(16).frame(width: 280) }
  }

  @ViewBuilder private var details: some View {
    if let diagnostics = store.endpoint?.diagnostics {
      VStack(alignment: .leading, spacing: 10) {
        Text("Connection Details").font(.headline)
        LabeledContent("Route", value: diagnostics.route)
        LabeledContent("Video", value: diagnostics.resolution)
        if let fps = diagnostics.framesPerSecond { LabeledContent("Presented", value: String(format: "%.1f fps", fps)) }
        if let rate = diagnostics.megabitsPerSecond {
          LabeledContent("Receiving", value: String(format: "%.2f Mbps", rate))
        }
        if let rtt = diagnostics.roundTripMilliseconds {
          LabeledContent("Round trip", value: String(format: "%.1f ms", rtt))
        }
        if let decode = diagnostics.decodeMilliseconds {
          LabeledContent("Decode p95", value: String(format: "%.2f ms", decode))
        }
        Text(diagnostics.decoder).font(.caption).foregroundStyle(.secondary)
      }
      .font(.callout)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("Connection Details").font(.headline)
        Text(store.message ?? "Connection details will appear when the screen share is ready.")
          .foregroundStyle(.secondary)
      }
      .font(.callout)
    }
  }
}
