#if os(iOS)
  import ScreenSharingConnection
  import SwiftUI

  struct ScreenSharingPaneStatus: View {
    let model: ScreenSharingPaneModel

    var body: some View {
      switch model.state {
      case .off, .connecting:
        ScreenSharingConnectingStatus(step: model.stillConnectingStep)
      case .reconnecting:
        ProgressView("Reconnecting…")
      case .live:
        EmptyView()
      case .failed(let reason):
        ScreenSharingFailedStatus(reason: reason, model: model)
      }
    }
  }

  private struct ScreenSharingConnectingStatus: View {
    let step: String?

    var body: some View {
      if let step {
        VStack(spacing: 8) {
          ProgressView()
          Text("Still connecting…").foregroundStyle(.secondary)
          Text(step).font(.footnote).foregroundStyle(.tertiary)
        }
      } else {
        ProgressView("Connecting to Mac…")
      }
    }
  }

  private struct ScreenSharingFailedStatus: View {
    let reason: ScreenSharingFailureReason
    let model: ScreenSharingPaneModel

    var body: some View {
      ContentUnavailableView {
        Label("Can't Show This Mac", systemImage: "display.trianglebadge.exclamationmark")
      } description: {
        Text(reason.sentence(on: model.machineName))
      } actions: {
        if holderIsKnown {
          Button("View here") { model.viewHere() }.buttonStyle(.borderedProminent)
        } else {
          Button("Try Again") { model.retry() }.buttonStyle(.borderedProminent)
        }
      }
    }

    private var holderIsKnown: Bool {
      switch reason {
      case .takenOver(by: .some), .inUse(by: .some): true
      default: false
      }
    }
  }
#endif
