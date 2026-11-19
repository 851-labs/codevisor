#if os(iOS)
  import SwiftUI

  struct PluginSetupCompactRow: View {
    let name: String
    let summary: String
    let icon: AnyView
    let accessory: PluginSetupCardAccessory.State
    let perform: () -> Void

    var body: some View {
      Button(action: perform) {
        HStack(spacing: 10) {
          icon
          VStack(alignment: .leading, spacing: 1) {
            Text(name)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
            Text(summary)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .lineLimit(1)
          Spacer(minLength: 8)
          PluginSetupCompactRowStatus(state: accessory)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .allowsHitTesting(isActionable)
      .accessibilityElement(children: .combine)
    }

    private var isActionable: Bool {
      if case .action(_, isEnabled: true) = accessory { true } else { false }
    }
  }

  private struct PluginSetupCompactRowStatus: View {
    let state: PluginSetupCardAccessory.State

    var body: some View {
      switch state {
      case let .action(title, isEnabled):
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
          .padding(.horizontal, 14)
          .padding(.vertical, 7)
          .background(.tint.opacity(0.14), in: Capsule())
      case .working:
        ProgressView().controlSize(.small).frame(minWidth: 56)
      case let .done(title):
        Label(title, systemImage: "checkmark")
          .font(.footnote.weight(.medium))
          .foregroundStyle(.secondary)
      case .unavailable:
        Text("Unavailable")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
#endif
