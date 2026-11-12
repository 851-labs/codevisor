import CodevisorCore
import CodevisorUI
import SwiftUI

struct SetupSheet<Steps: View>: View {
  let symbol: String
  let title: String
  var subtitle: String?
  let primaryTitle: String
  var cancelTitle = "Not Now"
  let canContinue: Bool
  let onCancel: () -> Void
  var onBack: (() -> Void)?
  let onContinue: () -> Void
  var stepsInCard = true
  var icon: AnyView?
  @ViewBuilder var steps: Steps

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 10) {
        if let icon {
          icon
        } else {
          Image(systemName: symbol)
            .font(.system(size: 30, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        VStack(spacing: 4) {
          Text(title)
            .font(.title3.weight(.semibold))
          if let subtitle {
            Text(subtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if stepsInCard {
        PermissionCard { steps }
      } else {
        steps
      }

      HStack {
        Button(cancelTitle, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Spacer()
        if let onBack {
          Button("Back", action: onBack)
        }
        Button(primaryTitle, action: onContinue)
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
