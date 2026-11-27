#if os(iOS)
  import SwiftUI

  struct ScreenSharingDisplaySwitchNotice: View {
    let model: ScreenSharingPaneModel

    var body: some View {
      if let failure = model.displaySwitchFailure, model.isViewing {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .glassEffect(.regular, in: .capsule)
          .transition(.move(edge: .top).combined(with: .opacity))
          .task(id: failure) {
            try? await Task.sleep(for: .seconds(4))
            model.dismissDisplaySwitchFailure()
          }
      }
    }
  }
#endif
