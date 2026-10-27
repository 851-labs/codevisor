#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    struct Metrics: Sendable, Equatable {
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
      public var groupLabelSize: CGFloat = 12
      public var groupLabelTopInset: CGFloat = 8
      public var groupLabelBottomInset: CGFloat = 4
      public var itemHeight: CGFloat = 24
      public var fontSize: CGFloat = NSFont.systemFontSize
      public var itemCornerRadius: CGFloat = 6
      public var itemHorizontalInset: CGFloat = 11
      public var itemIconSize: CGFloat = 16
      public var itemIconSpacing: CGFloat = 8
      public var checkColumnWidth: CGFloat = 14
      public var checkColumnSpacing: CGFloat = 6
      public var dividerHeight: CGFloat = 11
      public var itemAccessoryWidth: CGFloat = 22
      public var itemAccessoryTrailingInset: CGFloat = 2
      public var bottomCornerRadius: CGFloat = 14

      public init() {}

      public static let xcodeMenu = Metrics()

      public var checkColumnAdvance: CGFloat { checkColumnWidth + checkColumnSpacing }

      public func iconColumnCenter(showsCheckmarks: Bool = false) -> CGFloat {
        contentLeading(showsCheckmarks: showsCheckmarks) + itemIconSize / 2
      }

      public func textLeading(showsCheckmarks: Bool = false, showsIcons: Bool = false) -> CGFloat {
        contentLeading(showsCheckmarks: showsCheckmarks) + (showsIcons ? itemIconSize + itemIconSpacing : 0)
      }

      public func contentLeading(showsCheckmarks: Bool = false) -> CGFloat {
        listHorizontalInset + itemHorizontalInset + (showsCheckmarks ? checkColumnAdvance : 0)
      }

      public var nativeMenuFont: NSFont {
        NSFont.menuFont(ofSize: fontSize)
      }

      public var menuFont: Font {
        Font(nativeMenuFont)
      }

      public var groupLabelFont: Font {
        .system(size: groupLabelSize)
      }

      var groupLabelLineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: groupLabelSize)
        return ceil(font.ascender - font.descender + font.leading)
      }

      var checkmarkFontSize: CGFloat { fontSize * 12 / NSFont.systemFontSize }
      var accessoryFontSize: CGFloat { fontSize * 11 / NSFont.systemFontSize }

      func resolved(for dynamicTypeSize: DynamicTypeSize = .large) -> Self {
        var result = self
        if dynamicTypeSize.isAccessibilitySize {
          result.fontSize = max(fontSize, 19)
          result.groupLabelSize = max(groupLabelSize, 17)
        }
        let scale = result.fontSize / NSFont.systemFontSize
        result.groupLabelSize = max(result.groupLabelSize, result.fontSize - 1)
        result.itemIconSize = max(itemIconSize, ceil(16 * scale))
        result.checkColumnWidth = max(checkColumnWidth, ceil(14 * scale))
        result.itemAccessoryWidth = max(itemAccessoryWidth, ceil(22 * scale))
        result.itemHeight = max(itemHeight, ceil(result.fontSize * 1.6), result.itemIconSize)
        result.inputHeight = max(inputHeight, result.itemHeight + 4)
        return result
      }

      func listHeight(itemCount: Int, groupLabelCount: Int = 0, dividerCount: Int = 0) -> CGFloat {
        min(
          listContentHeight(itemCount: itemCount, groupLabelCount: groupLabelCount, dividerCount: dividerCount),
          max(0, maximumHeight - inputTopInset - inputHeight - inputBottomInset))
      }

      func listContentHeight(
        itemCount: Int, groupLabelCount: Int = 0, dividerCount: Int = 0
      ) -> CGFloat {
        guard itemCount > 0 else { return emptyListHeight }
        let labelHeight =
          groupLabelLineHeight
          + groupLabelTopInset
          + groupLabelBottomInset
        let contentHeight =
          (2 * listVerticalInset)
          + (CGFloat(groupLabelCount) * labelHeight)
          + (CGFloat(itemCount) * itemHeight)
          + (CGFloat(dividerCount) * dividerHeight)
        return ceil(contentHeight)
      }

      public func menuTextWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nativeMenuFont]).width)
      }

      public func popupWidth(
        fitting titles: [String],
        hasIcons: Bool = false,
        showsCheckmarks: Bool = false,
        shortcuts: [KeyboardShortcut] = [],
        accessoryCount: Int = 0
      ) -> CGFloat {
        var chrome =
          (2 * listHorizontalInset) + (2 * itemHorizontalInset) + CGFloat(accessoryCount) * itemAccessoryWidth
          + itemIconSpacing + 8
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

    enum ItemHighlight: Sendable {
      case menuSelection
      case fill(Color, foreground: Color = .white)

      public var foreground: Color {
        switch self {
        case .menuSelection: Color(nsColor: .selectedMenuItemTextColor)
        case let .fill(_, foreground): foreground
        }
      }
    }

    struct Style: Sendable {
      public var metrics: Metrics
      public var itemHighlight: ItemHighlight
      public var usesMiniScroller: Bool
      public var showsAccessories: Bool

      public init(
        metrics: Metrics = .xcodeMenu,
        itemHighlight: ItemHighlight = .menuSelection,
        usesMiniScroller: Bool = true,
        showsAccessories: Bool = true
      ) {
        self.metrics = metrics
        self.itemHighlight = itemHighlight
        self.usesMiniScroller = usesMiniScroller
        self.showsAccessories = showsAccessories
      }

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
