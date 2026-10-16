import SwiftUI
import CodevisorUI

struct SettingsDisclosureRow<Label: View, Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var isExpanded: Bool
  @ViewBuilder let label: () -> Label
  @ViewBuilder let content: () -> Content

  init(
    isExpanded: Binding<Bool>,
    @ViewBuilder label: @escaping () -> Label,
    @ViewBuilder content: @escaping () -> Content
  ) {
    _isExpanded = isExpanded
    self.label = label
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        var transaction = Transaction()
        transaction.animation = reduceMotion ? nil : .easeInOut(duration: 0.15)
        withTransaction(transaction) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.system(size: Typography.IconSize.disclosure, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          label()
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")

      if isExpanded {
        content()
      }
    }
  }
}

extension SettingsDisclosureRow where Label == SettingsDisclosureTitle {
  init(
    _ title: String,
    systemImage: String? = nil,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(isExpanded: isExpanded) {
      SettingsDisclosureTitle(systemImage: systemImage, title: title)
    } content: {
      content()
    }
  }
}

struct SettingsDisclosureTitle: View {
  let systemImage: String?
  let title: String

  var body: some View {
    HStack(spacing: 7) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: Typography.IconSize.chrome))
          .foregroundStyle(.secondary)
          .frame(width: 16)
          .accessibilityHidden(true)
      }
      Text(title)
        .foregroundStyle(.primary)
    }
  }
}
