#if os(macOS)
  import SwiftUI

  /// Standard sheet actions, independent of the controls in the sheet's
  /// content. Attach with `.safeAreaInset(edge: .bottom, spacing: 0)` on the
  /// view *outside* the `NavigationStack`, so the band is pinned below the
  /// scrolling body rather than inside it.
  ///
  /// `status` is the sheet's single blocking operation, if any. It takes the
  /// leading edge while the actions stay trailing. Putting it here rather
  /// than in the body is what keeps a macOS sheet from reflowing mid-
  /// operation: this band's height is set by its buttons, and
  /// `SheetActivityLabel` is deliberately shorter than a `.regular` control,
  /// so showing status cannot change the sheet's size.
  public struct SheetFooter<Actions: View>: View {
    @Environment(\.theme) private var theme
    private let status: String?
    private let actions: Actions

    public init(status: String? = nil, @ViewBuilder actions: () -> Actions) {
      self.status = status
      self.actions = actions()
    }

    public var body: some View {
      VStack(spacing: 0) {
        Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
        HStack(spacing: 12) {
          if let status {
            SheetActivityLabel(status)
          }
          Spacer()
          actions
        }
        // No blanket button style: `.automatic` renders the
        // `.keyboardShortcut(.defaultAction)` button prominent, which is the
        // AppKit sheet convention and lets a sheet's one primary action read
        // as primary without any body control competing for that role.
        .controlSize(.regular)
        .padding(20)
      }
      .animation(.default, value: status)
      .themedSurface(.sheet)
    }
  }
#endif
