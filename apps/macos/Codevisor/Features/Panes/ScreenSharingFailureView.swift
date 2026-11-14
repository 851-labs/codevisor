import SwiftUI

struct ScreenSharingFailureView: View {
  let pane: ScreenSharingPane
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
      Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
      Button("Retry", action: onRetry)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .simultaneousGesture(
      TapGesture().onEnded {
        pane.onFocusChanged?(true)
        pane.focus()
      }
    )
  }
}
