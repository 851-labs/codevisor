import CodevisorUI
import SwiftUI

struct BotMascotCategoryTabs: View {
  @Binding var selection: BotMascotCategory

  var body: some View {
    ViewThatFits(in: .horizontal) {
      tabs
      ScrollView(.horizontal, showsIndicators: false) { tabs }
    }
    .padding(.vertical, 12)
  }

  private var tabs: some View {
    HStack(spacing: 32) {
      ForEach(BotMascotCategory.allCases) { category in
        Button(category.title) { selection = category }
          .font(.title3.weight(.medium))
          .foregroundStyle(category == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .accessibilityAddTraits(category == selection ? .isSelected : [])
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal)
  }
}
