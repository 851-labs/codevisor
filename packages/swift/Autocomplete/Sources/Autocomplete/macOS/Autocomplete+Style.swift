#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    /// Xcode's searchable pickers use native menu typography and a 24-point
    /// item grid even though they are presented in a popover. Keeping those
    /// system metrics in one value prevents rows from drifting apart and lets
    /// a list size itself before it is laid out.
    struct Metrics: Sendable {
      public var minimumWidth: CGFloat = 220
      public var maximumWidth: CGFloat = 402
      public var maximumHeight: CGFloat = 430
      public var inputHeight: CGFloat = 28
      public var inputHorizontalInset: CGFloat = 8
      public var inputTopInset: CGFloat = 8
      public var inputBottomInset: CGFloat = 0
      public var listHorizontalInset: CGFloat = 5
      public var listVerticalInset: CGFloat = 4
      public var emptyListHeight: CGFloat = 64
      public var groupSpacing: CGFloat = 6
      public var groupLabelSize: CGFloat = 12
      public var groupLabelTopInset: CGFloat = 8
      public var groupLabelBottomInset: CGFloat = 4
      public var itemHeight: CGFloat = 24
      public var itemCornerRadius: CGFloat = 6
      public var itemHorizontalInset: CGFloat = 11
      /// The leading glyph slot on items that have one.
      public var itemIconSize: CGFloat = 18
      public var itemIconSpacing: CGFloat = 8
      /// Space reserved at an item's trailing edge for a hover accessory.
      public var itemAccessoryWidth: CGFloat = 22
      public var itemAccessoryTrailingInset: CGFloat = 2
      /// The bottom corners of the popup's last row (the footer, or the last
      /// item when there is none), so its highlight sits concentric with the
      /// popup's own corners instead of showing a sliver of background.
      public var bottomCornerRadius: CGFloat = 14

      public init() {}

      public static let xcodeMenu = Metrics()

      public var groupLabelInset: CGFloat { itemHorizontalInset }
      public var footerHorizontalInset: CGFloat { listHorizontalInset }
      public var footerVerticalInset: CGFloat { listHorizontalInset }
      public var footerTitleInset: CGFloat { itemHorizontalInset }

      public var nativeMenuFont: NSFont {
        NSFont.menuFont(ofSize: NSFont.systemFontSize)
      }

      public var menuFont: Font {
        Font(nativeMenuFont)
      }

      public var groupLabelFont: Font {
        .system(size: groupLabelSize)
      }

      /// The height of the scrolling list that fits `itemCount` rows and
      /// `groupLabelCount` group labels inside a popup with an input and a
      /// footer, capped at `maximumHeight` overall. Measure the unfiltered
      /// contents and pass the result to `List(height:)` so filtering never
      /// resizes the popover.
      public func listHeight(
        itemCount: Int,
        groupLabelCount: Int = 0,
        hasInput: Bool = true,
        hasFooter: Bool = false
      ) -> CGFloat {
        var chrome: CGFloat = 0
        if hasInput {
          chrome += inputTopInset + inputHeight + inputBottomInset
        }
        if hasFooter {
          chrome += 1 + itemHeight + (2 * footerVerticalInset)
        }
        return min(
          listContentHeight(itemCount: itemCount, groupLabelCount: groupLabelCount),
          maximumHeight - chrome
        )
      }

      /// `listHeight(itemCount:groupLabelCount:)` for grouped contents, one
      /// entry per group.
      public func listHeight(groupItemCounts: [Int], hasInput: Bool = true, hasFooter: Bool = false) -> CGFloat {
        listHeight(
          itemCount: groupItemCounts.reduce(0, +),
          groupLabelCount: groupItemCounts.count,
          hasInput: hasInput,
          hasFooter: hasFooter
        )
      }

      public func listContentHeight(itemCount: Int, groupLabelCount: Int = 0) -> CGFloat {
        guard itemCount > 0 else { return emptyListHeight }
        let labelHeight =
          ceil(NSFont.systemFont(ofSize: groupLabelSize).boundingRectForFont.height)
          + groupLabelTopInset
          + groupLabelBottomInset
        let contentHeight =
          (2 * listVerticalInset)
          + (CGFloat(groupLabelCount) * labelHeight)
          + (CGFloat(itemCount) * itemHeight)
          + (CGFloat(max(groupLabelCount - 1, 0)) * groupSpacing)
        return ceil(contentHeight)
      }

      public func menuTextWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nativeMenuFont]).width)
      }

      /// The narrowest width, within the configured bounds, that shows every
      /// title on one line with room for a trailing accessory.
      public func popupWidth(fitting titles: [String]) -> CGFloat {
        let chrome = (2 * listHorizontalInset) + (2 * itemHorizontalInset) + itemAccessoryWidth + 8
        let widest = titles.reduce(CGFloat.zero) { width, title in
          max(width, menuTextWidth(title) + chrome)
        }
        return min(max(ceil(widest), minimumWidth), maximumWidth)
      }
    }

    /// How a highlighted item is painted.
    enum ItemHighlight: Sendable {
      /// The system menu selection material (accent-tinted, appearance-aware).
      case menuSelection
      /// A flat fill, e.g. a theme accent on a glass surface.
      case fill(Color)
    }

    struct Style: Sendable {
      public var metrics: Metrics
      public var itemHighlight: ItemHighlight
      /// Whether the list shows the mini system scroller.
      public var usesMiniScroller: Bool

      public init(
        metrics: Metrics = .xcodeMenu,
        itemHighlight: ItemHighlight = .menuSelection,
        usesMiniScroller: Bool = true
      ) {
        self.metrics = metrics
        self.itemHighlight = itemHighlight
        self.usesMiniScroller = usesMiniScroller
      }

      /// The look of Xcode's searchable pickers (scheme, destination, …).
      public static let xcodeMenu = Style()
    }
  }

  extension EnvironmentValues {
    @Entry public var autocompleteStyle: Autocomplete.Style = .xcodeMenu
  }

  public extension View {
    func autocompleteStyle(_ style: Autocomplete.Style) -> some View {
      environment(\.autocompleteStyle, style)
    }
  }
#endif
