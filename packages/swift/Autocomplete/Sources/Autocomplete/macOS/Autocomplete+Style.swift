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
      public var itemIconSize: CGFloat = 16
      public var itemIconSpacing: CGFloat = 8
      /// The checkmark column a popup reserves when `Root(showsCheckmarks:)`
      /// is on, ahead of icons and titles — the way a menu does.
      public var checkColumnWidth: CGFloat = 14
      public var checkColumnSpacing: CGFloat = 6
      /// A `Divider` row: a hairline with breathing room above and below.
      public var dividerHeight: CGFloat = 11
      /// Space reserved at an item's trailing edge for a hover accessory.
      public var itemAccessoryWidth: CGFloat = 22
      public var itemAccessoryTrailingInset: CGFloat = 2
      /// The bottom corners of the popup's last row (the footer, or the last
      /// item when there is none), so its highlight sits concentric with the
      /// popup's own corners instead of showing a sliver of background.
      public var bottomCornerRadius: CGFloat = 14

      public init() {}

      public static let xcodeMenu = Metrics()

      /// How far the check column pushes everything after it.
      public var checkColumnAdvance: CGFloat { checkColumnWidth + checkColumnSpacing }

      /// Keylines shared by items and the input, measured from the popup's
      /// leading edge: where an item's icon is centered and where its title
      /// starts. The input places its magnifier and text on the same lines.
      public func iconColumnCenter(showsCheckmarks: Bool = false) -> CGFloat {
        contentLeading(showsCheckmarks: showsCheckmarks) + itemIconSize / 2
      }

      /// Where titles start. With an icon column (`Root(showsIcons:)`) that is
      /// past the column; otherwise titles begin at the content leading.
      public func textLeading(showsCheckmarks: Bool = false, showsIcons: Bool = false) -> CGFloat {
        contentLeading(showsCheckmarks: showsCheckmarks) + (showsIcons ? itemIconSize + itemIconSpacing : 0)
      }

      /// Where a row's content (check column excluded) begins.
      public func contentLeading(showsCheckmarks: Bool = false) -> CGFloat {
        listHorizontalInset + itemHorizontalInset + (showsCheckmarks ? checkColumnAdvance : 0)
      }

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
        dividerCount: Int = 0,
        hasInput: Bool = true,
        footerItemCount: Int = 0
      ) -> CGFloat {
        var chrome: CGFloat = 0
        if hasInput {
          chrome += inputTopInset + inputHeight + inputBottomInset
        }
        if footerItemCount > 0 {
          chrome += 1 + (CGFloat(footerItemCount) * itemHeight) + (2 * footerVerticalInset)
        }
        return min(
          listContentHeight(itemCount: itemCount, groupLabelCount: groupLabelCount, dividerCount: dividerCount),
          maximumHeight - chrome
        )
      }

      /// `listHeight(itemCount:groupLabelCount:)` for grouped contents, one
      /// entry per group.
      public func listHeight(groupItemCounts: [Int], hasInput: Bool = true, footerItemCount: Int = 0) -> CGFloat {
        listHeight(
          itemCount: groupItemCounts.reduce(0, +),
          groupLabelCount: groupItemCounts.count,
          hasInput: hasInput,
          footerItemCount: footerItemCount
        )
      }

      public func listContentHeight(itemCount: Int, groupLabelCount: Int = 0, dividerCount: Int = 0) -> CGFloat {
        guard itemCount > 0 else { return emptyListHeight }
        let labelHeight =
          ceil(NSFont.systemFont(ofSize: groupLabelSize).boundingRectForFont.height)
          + groupLabelTopInset
          + groupLabelBottomInset
        let contentHeight =
          (2 * listVerticalInset)
          + (CGFloat(groupLabelCount) * labelHeight)
          + (CGFloat(itemCount) * itemHeight)
          + (CGFloat(dividerCount) * dividerHeight)
          + (CGFloat(max(groupLabelCount - 1, 0)) * groupSpacing)
        return ceil(contentHeight)
      }

      public func menuTextWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nativeMenuFont]).width)
      }

      /// The narrowest width, within the configured bounds, that shows every
      /// title on one line with room for a trailing accessory, plus the icon
      /// slot and the widest shortcut when items use them.
      public func popupWidth(
        fitting titles: [String],
        hasIcons: Bool = false,
        showsCheckmarks: Bool = false,
        shortcuts: [KeyboardShortcut] = []
      ) -> CGFloat {
        var chrome = (2 * listHorizontalInset) + (2 * itemHorizontalInset) + itemAccessoryWidth + 8
        if hasIcons {
          chrome += itemIconSize + itemIconSpacing
        }
        if showsCheckmarks {
          chrome += checkColumnAdvance
        }
        let widestShortcut = shortcuts.reduce(CGFloat.zero) { width, shortcut in
          max(width, menuTextWidth(Autocomplete.symbols(for: shortcut)))
        }
        if widestShortcut > 0 {
          chrome += widestShortcut + 8
        }
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
    /// Set by `Root(showsCheckmarks:)`; rows, labels, dividers, and the
    /// input all leave room for the check column when it is on.
    @Entry var autocompleteShowsCheckmarks = false
    /// Set by `Root(showsIcons:)`; rows reserve the icon column even when a
    /// particular item has no icon, and the input keylines follow it.
    @Entry var autocompleteShowsIcons = false
  }

  public extension View {
    func autocompleteStyle(_ style: Autocomplete.Style) -> some View {
      environment(\.autocompleteStyle, style)
    }
  }
#endif
