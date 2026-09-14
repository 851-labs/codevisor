import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import SwiftUI

/// Window toolbar controls borrow the selected pane's model; the pane owns
/// the connection and control state across toolbar and menu updates.
struct ScreenSharingToolbar: ToolbarContent {
  let model: ScreenSharingViewerModel

  var body: some ToolbarContent {
    ToolbarItem(id: "screenSharing.mode", placement: .principal) {
      HStack(spacing: 8) { controlActions }
    }
    ToolbarItem(id: "screenSharing.size", placement: .primaryAction) {
      Picker("Size", selection: Binding(get: { model.preferences.fitToWindow }, set: { model.setFitToWindow($0) })) {
        Text("Fit").tag(true)
        Text("Actual Size").tag(false)
      }
      .labelsHidden().frame(width: 110)
    }
    if let clipboard = model.clipboard {
      ToolbarItem(id: "screenSharing.clipboard", placement: .primaryAction) {
        Menu {
          Button("Send Clipboard to Mac") { clipboard.sendLocalText() }
          Button("Get Clipboard from Mac") { clipboard.getRemoteText() }
        } label: {
          Image(systemName: "doc.on.clipboard")
        }
        .accessibilityLabel("Clipboard")
        .help("Transfer plain text between clipboards")
        .disabled(!clipboard.available || clipboard.busy)
      }
    }
    ToolbarItem(id: "screenSharing.details", placement: .primaryAction) {
      ScreenSharingDetailsButton(model: model).id(ObjectIdentifier(model))
    }
  }

  @ViewBuilder private var controlActions: some View {
    if model.phase == .viewing, let control = model.control {
      Picker(
        "Interaction mode",
        selection: Binding(
          get: { control.state != .viewing },
          set: { if $0 { control.request() } else { control.release() } })
      ) {
        Text("View").tag(false)
        Text("Control").tag(true)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .disabled(!control.available)
      .help("Send mouse, keyboard and app shortcuts to this Mac. Control–Option–Escape returns to viewing.")
      if control.state == .requesting {
        ProgressView().controlSize(.mini).accessibilityLabel("Requesting control")
      }
    } else {
      Text("View").foregroundStyle(.secondary)
    }
  }

}

private struct ScreenSharingDetailsButton: View {
  let model: ScreenSharingViewerModel
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
    if let diagnostics = model.diagnostics {
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
    }
  }
}
