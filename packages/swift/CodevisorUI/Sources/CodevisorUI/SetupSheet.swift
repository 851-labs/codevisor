#if os(macOS)
  import SwiftUI

  public struct SetupSheet<Steps: View>: View {
    private let symbol: String?
    private let title: String
    private let subtitle: String?
    private let primaryTitle: String?
    private let cancelTitle: String
    private let canContinue: Bool
    private let status: String?
    private let onCancel: () -> Void
    private let onBack: (() -> Void)?
    private let secondaryTitle: String?
    private let onSecondary: (() -> Void)?
    private let onContinue: () -> Void
    private let stepsInCard: Bool
    private let icon: AnyView?
    private let steps: Steps

    public init(
      symbol: String?,
      title: String,
      subtitle: String? = nil,
      primaryTitle: String?,
      cancelTitle: String = "Not Now",
      canContinue: Bool,
      status: String? = nil,
      onCancel: @escaping () -> Void,
      onBack: (() -> Void)? = nil,
      secondaryTitle: String? = nil,
      onSecondary: (() -> Void)? = nil,
      onContinue: @escaping () -> Void,
      stepsInCard: Bool = true,
      icon: AnyView? = nil,
      @ViewBuilder steps: () -> Steps
    ) {
      self.symbol = symbol
      self.title = title
      self.subtitle = subtitle
      self.primaryTitle = primaryTitle
      self.cancelTitle = cancelTitle
      self.canContinue = canContinue
      self.status = status
      self.onCancel = onCancel
      self.onBack = onBack
      self.secondaryTitle = secondaryTitle
      self.onSecondary = onSecondary
      self.onContinue = onContinue
      self.stepsInCard = stepsInCard
      self.icon = icon
      self.steps = steps()
    }

    public var body: some View {
      VStack(spacing: 20) {
        VStack(spacing: 10) {
          if let icon {
            icon
          } else if let symbol {
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

        ViewThatFits(in: .horizontal) {
          HStack {
            cancelButton(fills: false)
            Spacer()
            if let status {
              SheetActivityLabel(status)
            }
            if let onBack {
              Button("Back", action: onBack)
            }
            secondaryButton(fills: false)
            primaryButton(fills: false)
          }
          VStack(spacing: 8) {
            if let status {
              SheetActivityLabel(status)
            }
            primaryButton(fills: true)
            secondaryButton(fills: true)
            cancelButton(fills: true)
          }
        }
        .controlSize(.large)
        .animation(.snappy(duration: 0.2), value: canContinue)
      }
      .padding(24)
      .frame(width: 460)
    }

    private func cancelButton(fills: Bool) -> some View {
      Button(action: onCancel) { label(cancelTitle, fills: fills) }
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private func secondaryButton(fills: Bool) -> some View {
      if let secondaryTitle, let onSecondary {
        Button(action: onSecondary) { label(secondaryTitle, fills: fills) }
          .disabled(!canContinue)
      }
    }

    @ViewBuilder
    private func primaryButton(fills: Bool) -> some View {
      if let primaryTitle {
        Button(action: onContinue) { label(primaryTitle, fills: fills) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!canContinue)
      }
    }

    private func label(_ title: String, fills: Bool) -> some View {
      Text(title).frame(maxWidth: fills ? .infinity : nil)
    }
  }
#endif
