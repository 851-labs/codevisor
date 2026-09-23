#if os(iOS)
  import SwiftUI

  /// The confirmation slot of a sheet.
  ///
  /// Deliberately **text-labeled**. `Button(role: .confirm)` already renders
  /// prominent on iOS 26, so the label is free to carry the verb — and it
  /// must, because a bare `checkmark` for "Save" and a bare `arrow.right`
  /// for "Sign In" are not distinguishable, let alone guessable. Only
  /// dismissal (`role: .close`, an `xmark`) is universally understood
  /// enough to go icon-only.
  ///
  /// It does **not** show progress. Work in flight is reported once, by
  /// `SheetStatusBar`, exactly as macOS reports it once in `SheetFooter`;
  /// this button only disables. A button that swapped itself for a spinner
  /// could only ever key off the sheet's shared busy flag, which made an
  /// unrelated operation — signing an account out — look like *this*
  /// action was running.
  public struct SheetConfirmToolbarItem: ToolbarContent {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    public init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
      self.title = title
      self.isEnabled = isEnabled
      self.action = action
    }

    public var body: some ToolbarContent {
      ToolbarItem(placement: .confirmationAction) {
        Button(title, role: .confirm, action: action)
          .disabled(!isEnabled)
      }
    }
  }
#endif
