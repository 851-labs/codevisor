import SwiftUI

/// The one way a sheet says "something is happening".
///
/// Sheets in this app express activity in exactly three states, and all
/// three use this label so the pixels are identical wherever they land:
///
/// 1. **Initial load** — nothing to show yet. `SheetLoadingView` wraps this
///    to fill the body.
/// 2. **Blocking operation** — the user started it and the body is
///    `.disabled` until it finishes. This renders in the sheet's *chrome*:
///    `SheetFooter(status:)` on macOS, the confirmation toolbar slot on
///    iOS. **Never in the body.** A macOS sheet is frame-sized, so a strip
///    appearing inside it reflows the whole form; a footer's height is
///    driven by its buttons, so status there cannot resize anything.
/// 3. **Ambient wait** — the body *is* the wait (the user is finishing a
///    sign-in in their browser and this sheet is the receipt). This one
///    belongs in the body, because it is the sheet's subject rather than
///    an interruption of it.
///
/// Deliberately shorter than a `.regular` control (a `.small` spinner and
/// `.callout` text) so that placing it beside footer buttons can never
/// change the footer's height.
public struct SheetActivityLabel: View {
  @Environment(\.theme) private var theme
  private let title: String

  public init(_ title: String = "Waiting for sign-in…") {
    self.title = title
  }

  public var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .tint(theme.isSystem ? nil : theme.accent)
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
