import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import SwiftUI

struct ScreenSharingToolbar: View {
  let model: ScreenSharingViewerModel
  let machineName: String
  @State private var showDiagnostics = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          display; Spacer(minLength: 8); controls
        }
        VStack(alignment: .leading, spacing: 8) {
          display
          controls
        }
      }
      if model.control?.state == .controlling {
        Text("⌃⌥Esc releases control").font(.caption).foregroundStyle(.secondary)
      }
    }
    .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
  }

  private var display: some View {
    HStack(spacing: 8) {
      Image(systemName: "display")
      if !model.displays.isEmpty {
        Picker("Display", selection: Binding(get: { model.selectedDisplayId ?? "" }, set: { model.selectDisplay($0) }))
        {
          if model.selectedDisplayId == nil { Text("Choose a display").tag("") }
          ForEach(model.displays) { display in
            Text("\(display.name) · \(display.width) × \(display.height)").tag(display.id)
          }
        }
        .labelsHidden().frame(idealWidth: 300, maxWidth: 300)
      } else {
        Text(machineName).lineLimit(1)
      }
    }
  }

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        controlActions; videoActions
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          controlActions; Spacer(minLength: 0)
        }
        HStack {
          videoActions; Spacer(minLength: 0)
        }
      }
    }
  }

  @ViewBuilder private var controlActions: some View {
    if model.phase == .viewing, let control = model.control {
      if control.state == .controlling {
        Button("Stop Control") { control.release() }
      } else if control.state == .requesting {
        Button("Cancel Control") { control.release() }
      } else {
        Text("View Only").foregroundStyle(.secondary)
        Button("Control") { control.request() }.disabled(!control.available)
          .help("Send mouse, keyboard and app shortcuts to this Mac. Control–Option–Escape returns to viewing.")
      }
    } else {
      Text("View Only").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var videoActions: some View {
    if model.phase == .viewing || model.phase == .connecting || model.phase == .reconnecting {
      Picker("Size", selection: Binding(get: { model.preferences.fitToWindow }, set: { model.setFitToWindow($0) })) {
        Text("Fit").tag(true)
        Text("Actual Size").tag(false)
      }
      .labelsHidden().frame(width: 110)
      if let clipboard = model.clipboard {
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
      Button {
        showDiagnostics.toggle()
      } label: {
        Image(systemName: "info.circle")
      }
      .accessibilityLabel("Connection Details")
      .popover(isPresented: $showDiagnostics) { details.padding(16).frame(width: 280) }
      Button("Disconnect") { model.disconnect() }
    } else {
      Button("Connect") { model.connect() }
        .disabled(model.selectedDisplayId == nil || model.phase == .loading)
    }
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
