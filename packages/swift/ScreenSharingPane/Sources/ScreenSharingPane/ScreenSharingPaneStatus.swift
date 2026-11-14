#if os(iOS)
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
      case .failed:
        ScreenSharingFailedStatus(model: model)
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
    let model: ScreenSharingPaneModel

    var body: some View {
      ContentUnavailableView {
        Label("Can't Show This Desktop", systemImage: "display.trianglebadge.exclamationmark")
      } description: {
        Text(model.failure?.sentence ?? "")
      } actions: {
        switch model.failure?.action {
        case .viewHere: Button("View here") { model.viewHere() }.buttonStyle(.borderedProminent)
        case .tryAgain: Button("Try Again") { model.retry() }.buttonStyle(.borderedProminent)
        case nil: EmptyView()
        }
      }
    }
  }
#endif
