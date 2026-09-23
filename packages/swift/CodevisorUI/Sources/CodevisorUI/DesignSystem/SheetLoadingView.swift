import SwiftUI

/// State 1 of the three described on `SheetActivityLabel`: the sheet has
/// nothing to show yet, so the wait fills the body.
///
/// Uses a labeled `ProgressView` rather than `SheetActivityLabel`'s
/// horizontal row: centered in an otherwise-empty body, the platform
/// convention is a spinner with its caption beneath it. The horizontal row
/// is for activity *alongside* content.
///
/// Always pass the specific noun being waited on ("Loading accounts…",
/// "Loading providers…"). A bare spinner tells the user nothing about
/// which of several round-trips is in flight.
public struct SheetLoadingView: View {
  @Environment(\.theme) private var theme
  private let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    ProgressView(title)
      .controlSize(.small)
      .tint(theme.isSystem ? nil : theme.accent)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
