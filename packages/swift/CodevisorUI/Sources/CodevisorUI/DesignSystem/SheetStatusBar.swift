#if os(iOS)
  import SwiftUI

  /// A sheet's single in-progress operation, pinned below the scrolling body.
  /// The iOS counterpart of macOS's `SheetFooter(status:)`, and the reason
  /// the rule on `SheetActivityLabel` — status renders in chrome, never in
  /// the body — now holds on both platforms.
  ///
  /// Attach with `.sheetStatus(_:)` rather than constructing this directly.
  ///
  /// The height invariance that makes this safe is real on iOS too, by a
  /// different mechanism than macOS: a sheet here is detent-sized, so the
  /// band shrinks the scroll area instead of resizing the sheet. What it
  /// buys over the Form row this replaces is that the list no longer shifts
  /// under the user's finger the moment an operation starts.
  public struct SheetStatusBar: View {
    private let status: String?

    public init(_ status: String?) { self.status = status }

    public var body: some View {
      if let status {
        VStack(spacing: 0) {
          Divider()
          HStack(spacing: 0) {
            SheetActivityLabel(status)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        // `.bar` is the established material for a bottom band inside an
        // iOS sheet here; no themed surface, because `apps/ios` applies
        // none and this is not the place to introduce the first.
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  extension View {
    /// Pins `status` below the sheet body, or nothing when it is nil.
    ///
    /// On a sheet root, attach outside the `NavigationStack` so the band
    /// stays put across pushes — the placement macOS uses for `SheetFooter`.
    /// On a pushed page, attach to that page's own list so each page
    /// reports the work it started.
    public func sheetStatus(_ status: String?) -> some View {
      safeAreaInset(edge: .bottom, spacing: 0) { SheetStatusBar(status) }
        .animation(.default, value: status)
    }
  }
#endif
