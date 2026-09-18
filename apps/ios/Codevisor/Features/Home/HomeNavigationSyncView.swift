import SwiftUI

/// Native iOS catch-up and unavailable presentations for the selected
/// machine's navigation projection. Both replace cached rows so the screen
/// never presents stale data as current.
struct HomeNavigationSyncView: View {
  enum State {
    case loading(machineName: String)
    case failed(machineName: String)
  }

  let state: State
  var retry: (() -> Void)? = nil

  var body: some View {
    switch state {
    case let .loading(machineName):
      DelayedNavigationSyncProgressView(machineName: machineName)
    case let .failed(machineName):
      ContentUnavailableView {
        Label("Unable to Sync", systemImage: "exclamationmark.triangle")
      } description: {
        Text(
          "Codevisor couldn’t sync with \(machineName). "
            + "Make sure the machine is online, then try again.")
      } actions: {
        if let retry {
          Button("Try Again", action: retry)
            .buttonStyle(.borderedProminent)
        }
      }
    }
  }
}

/// Fast reconciliations remain visually quiet. SwiftUI cancels the task when
/// catch-up finishes, so a spinner can never flash after this view disappears.
private struct DelayedNavigationSyncProgressView: View {
  let machineName: String

  @State private var showsSpinner = false

  var body: some View {
    ZStack {
      Color.clear

      if showsSpinner {
        ProgressView()
          .controlSize(.regular)
          .accessibilityLabel("Syncing with \(machineName)")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: machineName) {
      showsSpinner = false
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      showsSpinner = true
    }
  }
}

/// Subtle overlay sync indicator that doesn't disrupt existing content layout.
/// Shows during buffered catch-up to indicate work is happening without causing shifts.
struct NavigationSyncOverlay: View {
  let machineName: String
  let bufferedEvents: Int
  
  @State private var showsIndicator = false
  
  var body: some View {
    VStack {
      Spacer()
      HStack {
        Spacer()
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          VStack(alignment: .leading, spacing: 2) {
            Text("Syncing")
              .font(.caption.weight(.medium))
            if bufferedEvents > 0 {
              Text("\(bufferedEvents) updates")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .opacity(showsIndicator ? 1 : 0)
        .scaleEffect(showsIndicator ? 1 : 0.8)
        Spacer()
      }
      .padding(.bottom, 16)
    }
    .allowsHitTesting(false)
    .task(id: "\(machineName)-\(bufferedEvents)") {
      showsIndicator = false
      do {
        try await Task.sleep(for: .milliseconds(300))
      } catch {
        return
      }
      withAnimation(.spring(duration: 0.3)) {
        showsIndicator = true
      }
    }
  }
}
