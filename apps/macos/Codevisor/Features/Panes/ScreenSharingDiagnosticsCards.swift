import Foundation
import ScreenSharing
import SwiftUI

struct ScreenSharingDiagnosticsCards: View {
  let diagnostics: ScreenSharingViewerDiagnostics

  private static let spacing: CGFloat = 10

  var body: some View {
    VStack(spacing: Self.spacing) {
      connection
      video
      if hasUpdateStats { updates }
      if let timeline = diagnostics.timeline { ScreenSharingTimelineDetails(timeline: timeline) }
    }
  }

  private var hasUpdateStats: Bool {
    diagnostics.updatesPerSecond != nil || diagnostics.bytesPerUpdate != nil
      || diagnostics.updateLatencyMilliseconds != nil
  }

  private var connection: some View {
    ScreenSharingDetailsCard {
      if let engine = diagnostics.engine { LabeledContent("Engine", value: engine) }
      LabeledContent("Route", value: diagnostics.route)
      if let rtt = diagnostics.roundTripMilliseconds {
        LabeledContent("Round trip", value: String(format: "%.1f ms", rtt))
      }
      if let rate = diagnostics.megabitsPerSecond {
        LabeledContent("Receiving", value: String(format: "%.2f Mbps", rate))
      }
      if let recovery = diagnostics.recovery { LabeledContent("Recovery", value: recovery) }
      if let streams = diagnostics.streams { LabeledContent("Streams", value: streams) }
    }
  }

  private var video: some View {
    ScreenSharingDetailsCard {
      LabeledContent("Resolution", value: diagnostics.resolution)
      if let fps = diagnostics.framesPerSecond {
        LabeledContent("Presented", value: String(format: "%.1f fps", fps))
      }
      LabeledContent("Decoder", value: diagnostics.decoder)
      if let decode = diagnostics.decodeMilliseconds {
        LabeledContent("Decode p95", value: String(format: "%.2f ms", decode))
      }
    }
  }

  private var updates: some View {
    ScreenSharingDetailsCard {
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
    }
  }
}
