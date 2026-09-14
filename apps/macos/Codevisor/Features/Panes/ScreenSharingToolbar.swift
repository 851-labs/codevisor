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
      controlActions
    }
    ToolbarItem(id: "screenSharing.size", placement: .primaryAction) {
      Picker("Size", selection: Binding(get: { model.preferences.fitToWindow }, set: { model.setFitToWindow($0) })) {
        Text("Fit").tag(true)
        Text("Actual Size").tag(false)
      }
      .labelsHidden().frame(width: 110)
    }
    ToolbarItem(id: "screenSharing.clipboard", placement: .primaryAction) {
      Menu {
        Group {
          Button("Send Clipboard to Mac") { model.clipboard?.sendLocalText() }
          Button("Get Clipboard from Mac") { model.clipboard?.getRemoteText() }
        }
        .disabled(model.clipboard?.available != true || model.clipboard?.busy == true)
      } label: {
        Image(systemName: "doc.on.clipboard")
      }
      .accessibilityLabel("Clipboard")
      .help("Transfer plain text between clipboards")
    }
    ToolbarItem(id: "screenSharing.details", placement: .primaryAction) {
      ScreenSharingDetailsButton(model: model).id(ObjectIdentifier(model))
    }
  }

  private var controlActions: some View {
    Picker(
      "Interaction mode",
      selection: Binding(get: { model.interactionMode }, set: { model.setInteractionMode($0) })
    ) {
      Text("View").tag(ScreenSharingViewerModel.InteractionMode.view)
      Text("Control").tag(ScreenSharingViewerModel.InteractionMode.control)
    }
    .pickerStyle(.segmented).labelsHidden().fixedSize()
    .help("Send mouse, keyboard and app shortcuts to this Mac. Control–Option–Escape returns to viewing.")
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
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("Connection Details").font(.headline)
        Text(model.message ?? "Connection details will appear when the screen share is ready.")
          .foregroundStyle(.secondary)
      }
      .font(.callout)
    }
  }
}
