import AppKit
import ACPKit
import CodevisorCore
import SwiftUI

struct ModelMenuGroup: Identifiable {
    let id: String
    let name: String
    let symbolName: String
    let modelOption: SessionConfigOption

    func matchingModels(query: String) -> [SessionConfigSelectOption] {
        guard !query.isEmpty else { return modelOption.options }
        if name.localizedCaseInsensitiveContains(query) { return modelOption.options }
        return modelOption.options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.value.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Xcode's searchable pickers use native menu typography and a 24-point item
/// grid even though they are presented in a popover. Keeping those system
/// metrics in one place prevents the individual rows from drifting apart.
enum XcodeModelPickerMetrics {
    static let popoverMinimumWidth: CGFloat = 220
    static let popoverMaximumWidth: CGFloat = 402
    static let popoverMaximumHeight: CGFloat = 430
    static let searchFieldHeight: CGFloat = 28
    static let searchHorizontalInset: CGFloat = 8
    static let searchTopInset: CGFloat = 8
    static let searchBottomInset: CGFloat = 0
    static let listHorizontalInset: CGFloat = 5
    static let listVerticalInset: CGFloat = 4
    static let emptyListHeight: CGFloat = 64
    static let sectionSpacing: CGFloat = 6
    static let sectionTitleTopInset: CGFloat = 8
    static let sectionTitleBottomInset: CGFloat = 4
    static let rowHeight: CGFloat = 24
    static let rowCornerRadius: CGFloat = 6
    static let rowHorizontalInset: CGFloat = 11
    static let rowFavoriteActionWidth: CGFloat = 22
    static let rowFavoriteActionTrailingInset: CGFloat = 2
    static let modelSectionTitleInset = rowHorizontalInset
    static let footerHorizontalInset = listHorizontalInset
    static let footerVerticalInset = listHorizontalInset
    static let footerTitleInset = rowHorizontalInset
    static let footerBottomCornerRadius: CGFloat = 14

    static var menuFont: Font {
        Font(NSFont.menuFont(ofSize: 0))
    }

    static var sectionFont: Font {
        .system(size: 12)
    }

    static func listHeight(sectionItemCounts: [Int]) -> CGFloat {
        let fixedChromeHeight =
            searchTopInset
            + searchFieldHeight
            + searchBottomInset
            + 1
            + rowHeight
            + (2 * footerVerticalInset)
        return min(
            listContentHeight(sectionItemCounts: sectionItemCounts),
            popoverMaximumHeight - fixedChromeHeight
        )
    }

    static func listContentHeight(sectionItemCounts: [Int]) -> CGFloat {
        guard !sectionItemCounts.isEmpty else { return emptyListHeight }
        let sectionTitleHeight =
            ceil(NSFont.systemFont(ofSize: 12).boundingRectForFont.height)
            + sectionTitleTopInset
            + sectionTitleBottomInset
        let contentHeight =
            (2 * listVerticalInset)
            + (CGFloat(sectionItemCounts.count) * sectionTitleHeight)
            + (CGFloat(sectionItemCounts.reduce(0, +)) * rowHeight)
            + (CGFloat(max(sectionItemCounts.count - 1, 0)) * sectionSpacing)
        return ceil(contentHeight)
    }

    static func menuTextWidth(_ text: String) -> CGFloat {
        ceil(
            (text as NSString).size(
                withAttributes: [.font: NSFont.menuFont(ofSize: 0)]
            ).width
        )
    }

    static func popoverWidth(for modelGroups: [ModelMenuGroup]) -> CGFloat {
        let regularRowChrome =
            (2 * listHorizontalInset)
            + (2 * rowHorizontalInset)
            + rowFavoriteActionWidth
            + 8
        let regularTitles =
            modelGroups.flatMap { group in
                [group.name] + group.modelOption.options.map(\.name)
            } + ["Manage Harnesses…"]
        let widestRegularRow = regularTitles.reduce(CGFloat.zero) { width, title in
            max(width, menuTextWidth(title) + regularRowChrome)
        }

        return min(
            max(ceil(widestRegularRow), popoverMinimumWidth),
            popoverMaximumWidth
        )
    }
}
