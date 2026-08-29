import ACPKit
import CodevisorCore
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
                .padding(.top, 8)
                .padding(.bottom, 4)

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

struct ModelPickerSignInSection: View {
    let harnesses: [ServerHarness]
    let highlightedTarget: ModelPickerKeyboardTarget?
    let onHover: (ModelPickerKeyboardTarget, Bool) -> Void
    let onSelect: (ServerHarness) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in required")
                .font(XcodeModelPickerMetrics.sectionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, XcodeModelPickerMetrics.harnessSectionTitleInset)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(harnesses, id: \.id) { harness in
                let target = ModelPickerKeyboardTarget.signIn(harnessID: harness.id)
                XcodeHarnessSignInRow(
                    harness: harness,
                    isKeyboardHighlighted: highlightedTarget == target,
                    onHover: { onHover(target, $0) },
                    action: { onSelect(harness) }
                )
                .id(target)
            }
        }
    }
}
