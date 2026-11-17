import SwiftUI

public struct SettingsDisclosureRow<Label: View, Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var isExpanded: Bool
  let chevronEdge: HorizontalEdge
  @ViewBuilder let label: () -> Label
  @ViewBuilder let content: () -> Content

  public init(
    isExpanded: Binding<Bool>,
    chevronEdge: HorizontalEdge = .leading,
    @ViewBuilder label: @escaping () -> Label,
    @ViewBuilder content: @escaping () -> Content
  ) {
    _isExpanded = isExpanded
    self.chevronEdge = chevronEdge
    self.label = label
    self.content = content
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        var transaction = Transaction()
        transaction.animation = reduceMotion ? nil : .easeInOut(duration: 0.15)
        withTransaction(transaction) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 7) {
          if chevronEdge == .leading { chevron }
          label()
          Spacer(minLength: 0)
          if chevronEdge == .trailing { chevron }
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

extension SettingsDisclosureRow {
  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: Typography.IconSize.disclosure, weight: .semibold))
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }
}

public extension SettingsDisclosureRow where Label == SettingsDisclosureTitle {
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

public struct SettingsDisclosureTitle: View {
  let systemImage: String?
  let title: String

  public init(systemImage: String?, title: String) {
    self.systemImage = systemImage
    self.title = title
  }

  public var body: some View {
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
