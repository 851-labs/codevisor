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
    private let onContinue: () -> Void
    private let onDelete: (() -> Void)?
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
      onContinue: @escaping () -> Void,
      onDelete: (() -> Void)? = nil,
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
      self.onContinue = onContinue
      self.onDelete = onDelete
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

        HStack {
          Button(cancelTitle, action: onCancel)
            .keyboardShortcut(.cancelAction)
          if let onDelete {
            Button("Delete", role: .destructive, action: onDelete)
              .foregroundStyle(.red)
              .disabled(status != nil)
          }
          Spacer()
          if let status {
            SheetActivityLabel(status)
          }
          if let onBack {
            Button("Back", action: onBack)
          }
          if let primaryTitle {
            Button(primaryTitle, action: onContinue)
              .buttonStyle(.borderedProminent)
              .keyboardShortcut(.defaultAction)
              .disabled(!canContinue)
          }
        }
        .controlSize(.large)
        .animation(.snappy(duration: 0.2), value: canContinue)
      }
      .padding(24)
      .frame(width: 460)
    }
  }
#endif
