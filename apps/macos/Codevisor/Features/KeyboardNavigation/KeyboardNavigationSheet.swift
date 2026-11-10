import SwiftUI

struct KeyboardNavigationSheet: View {
  let setting: KeyboardNavigationSetting
  let onNotNow: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text("Tab through everything")
          .font(.title2.weight(.bold))
        Text("Turn on keyboard navigation for your Mac.")
          .foregroundStyle(.secondary)
      }
      KeyboardNavigationFocusDemo()
      HStack {
        Button("Not Now", action: notNow)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Turn On", action: turnOn)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
    }
    .padding(24)
    .frame(width: 380)
  }

  private func notNow() {
    onNotNow()
    dismiss()
  }

  private func turnOn() {
    setting.turnOn()
    dismiss()
  }
}
