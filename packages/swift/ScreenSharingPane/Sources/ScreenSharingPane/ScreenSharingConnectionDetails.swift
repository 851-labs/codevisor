#if os(iOS)
  import ScreenSharing
  import SwiftUI

  struct ScreenSharingConnectionDetails: View {
    let model: ScreenSharingPaneModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        Form {
          if let diagnostics = model.diagnostics, model.phase == .viewing {
            rows(diagnostics)
          } else {
            Text("Connection details will appear when the screen share is ready.")
              .foregroundStyle(.secondary)
          }
        }
        .navigationTitle("Connection Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
      .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func rows(_ diagnostics: ScreenSharingViewerDiagnostics) -> some View {
      Section {
        if let engine = diagnostics.engine { LabeledContent("Engine", value: engine) }
        LabeledContent("Route", value: diagnostics.route)
        LabeledContent("Video", value: diagnostics.resolution)
        if let fps = diagnostics.framesPerSecond {
          LabeledContent("Presented", value: String(format: "%.1f fps", fps))
        }
        if let rate = diagnostics.megabitsPerSecond {
          LabeledContent("Receiving", value: String(format: "%.2f Mbps", rate))
        }
        if let rtt = diagnostics.roundTripMilliseconds {
          LabeledContent("Round trip", value: String(format: "%.1f ms", rtt))
        }
        if let decode = diagnostics.decodeMilliseconds {
          LabeledContent("Decode p95", value: String(format: "%.2f ms", decode))
        }
        if let recovery = diagnostics.recovery { LabeledContent("Recovery", value: recovery) }
        if let connectTime = diagnostics.connectTime { LabeledContent("Connected in", value: connectTime) }
      } footer: {
        Text(diagnostics.decoder)
      }
      if let timeline = diagnostics.timeline { ScreenSharingTimelineSection(timeline: timeline) }
    }
  }
#endif
