import ACPKit
import SwiftUI

struct ModelPickerModelSection: View {
    let title: String
    let items: [ModelPickerModelItem]
    let favoriteAction: ModelPickerFavoriteAction
    let highlightedTarget: ModelPickerKeyboardTarget?
    let isDisabled: Bool
    let isSelected: (ModelPickerModelItem) -> Bool
    let onHover: (ModelPickerKeyboardTarget, Bool) -> Void
    let onFavoriteAction: (ModelPickerModelItem) -> Void
    let onSelect: (ModelPickerModelItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(XcodeModelPickerMetrics.sectionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, XcodeModelPickerMetrics.modelSectionTitleInset)
                .padding(.top, XcodeModelPickerMetrics.sectionTitleTopInset)
                .padding(.bottom, XcodeModelPickerMetrics.sectionTitleBottomInset)

            ForEach(items) { item in
                XcodeModelPickerRow(
                    title: item.model.name,
                    isSelected: isSelected(item),
                    isKeyboardHighlighted: highlightedTarget == item.id,
                    isDisabled: isDisabled,
                    favoriteAction: favoriteAction,
                    onHover: { onHover(item.id, $0) },
                    onFavoriteAction: { onFavoriteAction(item) },
                    action: { onSelect(item) }
                )
                .id(item.id)
            }
        }
    }
}
