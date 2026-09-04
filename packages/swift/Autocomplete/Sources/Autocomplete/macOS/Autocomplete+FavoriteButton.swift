#if canImport(AppKit)
  import SwiftUI

  public extension Autocomplete {
    /// A star toggle for an item's hover-revealed accessory slot. It does
    /// not select the row or dismiss the menu.
    struct FavoriteButton: View {
      let action: FavoriteAction
      let perform: () -> Void

      public init(_ action: FavoriteAction, perform: @escaping () -> Void) {
        self.action = action
        self.perform = perform
      }

      public var body: some View {
        Button(action: perform) {
          Image(systemName: action.symbolName)
            .font(.system(size: 11, weight: .regular))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.label)
        .accessibilityLabel(action.label)
      }
    }
  }
#endif
