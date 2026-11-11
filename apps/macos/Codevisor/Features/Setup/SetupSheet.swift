import CodevisorCore
import CodevisorUI
import SwiftUI

struct SetupSheet<Steps: View>: View {
  let symbol: String
  let title: String
  let primaryTitle: String
  var cancelTitle = "Not Now"
  let canContinue: Bool
  var working = false
  var message: String?
  let onCancel: () -> Void
  let onContinue: () -> Void
  @ViewBuilder var steps: Steps

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 30, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(title)
          .font(.title3.weight(.semibold))
      }

      VStack(spacing: 10) {
        PermissionCard { steps }
        if let message {
          Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }

      HStack {
        Button(cancelTitle, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(action: onContinue) { SetupSheetPrimaryLabel(title: primaryTitle, working: working) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!canContinue)
      }
      .controlSize(.large)
      .animation(.snappy(duration: 0.2), value: canContinue)
    }
    .padding(24)
    .frame(width: 460)
  }
}

private struct SetupSheetPrimaryLabel: View {
  let title: String
  let working: Bool

  var body: some View {
    ZStack {
      Text(title).opacity(working ? 0 : 1)
      if working { ProgressView().controlSize(.small) }
    }
  }
}
