import CodevisorCoreMac
import SwiftUI

struct ScreenSharingDisplaySwitchBanner: View {
  let line: ScreenSharingDisplaySwitchLine
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if case .switching = line { ProgressView().controlSize(.mini) }
      Text(line.text).font(.caption).foregroundStyle(.secondary)
      Spacer()
      if case .failed = line {
        Button("Dismiss", systemImage: "xmark", action: dismiss)
          .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
          .help("Hide this message")
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }
}
