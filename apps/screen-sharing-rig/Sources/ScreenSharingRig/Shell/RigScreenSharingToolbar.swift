#if os(macOS)
  import CodevisorCoreMac
  import ComposableArchitecture
  import SwiftUI

  /// The product's Screen Sharing window toolbar
  /// (`apps/macos/Codevisor/Features/Panes/ScreenSharingToolbar.swift`) over
  /// the same `ScreenSharingViewer` store: View/Control, display menu,
  /// clipboard and connection details. Keep the two in step; the rig's copy
  /// says "machine" where the product says "Mac".
  struct RigScreenSharingToolbar: ToolbarContent {
    @Bindable var store: StoreOf<ScreenSharingViewer>
    /// Where the rig remembers this machine's Dynamic Resolution choice.
    let machineId: String

    var body: some ToolbarContent {
      ToolbarItem(id: "screenSharing.mode", placement: .principal) {
        HStack {
          if store.endpoint?.supportsControl != false { controlActions }
          if store.endpoint?.supportsDynamicResolution == true {
            ScreenSharingDynamicResolutionToggle(store: store) {
              RigMachineSettings.setDynamicResolution($0, for: machineId)
            }
          }
        }
      }
      ToolbarItem(id: "screenSharing.display", placement: .primaryAction) {
        if store.displays.count > 1 { displayMenu }
      }
      ToolbarItem(id: "screenSharing.clipboard", placement: .primaryAction) {
        if store.endpoint?.supportsClipboard != false {
          Menu {
            Group {
              Button("Send Clipboard to Machine") { store.endpoint?.clipboard?.sendLocalText() }
              Button("Get Clipboard from Machine") { store.endpoint?.clipboard?.getRemoteText() }
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
        RigScreenSharingDetailsButton(store: store).id(ObjectIdentifier(store))
      }
    }

    private var displayMenu: some View {
      Picker(
        "Display",
        selection: Binding(
          get: { store.selectedDisplayId ?? store.displays.first?.id ?? "" },
          set: { store.send(.displaySelected($0)) })
      ) {
        ForEach(store.displays) { display in Text(display.name).tag(display.id) }
      }
      .pickerStyle(.menu).labelsHidden().fixedSize()
      .help("Switch to another display of this machine")
    }

    private var controlActions: some View {
      Picker("Interaction mode", selection: $store.interactionMode.sending(\.interactionModeChanged)) {
        Label("View", systemImage: "binoculars").labelStyle(.iconOnly)
          .help("View only")
          .tag(ScreenSharingViewer.InteractionMode.view)
        Label("Control", systemImage: "cursorarrow.click.2").labelStyle(.iconOnly)
          .help("Control this machine")
          .tag(ScreenSharingViewer.InteractionMode.control)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .help("Send mouse, keyboard and app shortcuts to this machine. Control–Option–Escape returns to viewing.")
    }
  }

  private struct RigScreenSharingDetailsButton: View {
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
          if let fps = diagnostics.framesPerSecond {
            LabeledContent("Presented", value: String(format: "%.1f fps", fps))
          }
          if let rate = diagnostics.megabitsPerSecond {
            LabeledContent("Receiving", value: String(format: "%.2f Mbps", rate))
          }
          if let updates = diagnostics.updatesPerSecond {
            LabeledContent("Updates", value: String(format: "%.1f /s", updates))
          }
          if let size = diagnostics.bytesPerUpdate {
            LabeledContent(
              "Per update", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .binary))
          }
          if let latency = diagnostics.updateLatencyMilliseconds {
            LabeledContent("Update latency p95", value: String(format: "%.0f ms", latency))
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
#endif
