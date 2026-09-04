import Autocomplete
import CodevisorUI
import SwiftUI

/// What a `RunPickerMenu`'s rows need from the shell: the trimmed query to
/// filter by, and a way to close the popup once a row has acted.
struct RunPickerContext {
  let query: String
  let dismiss: () -> Void

  /// Case- and diacritic-insensitive containment; everything matches an
  /// empty query.
  func matches(_ title: String) -> Bool {
    query.isEmpty || Autocomplete.Filter.contains.matches(title, query: query)
  }
}

/// The "Manage…" / "New…" action pinned under a `RunPickerMenu`'s list.
struct RunPickerFooter<Target: Hashable> {
  let id: Target
  let title: String
  let symbol: String
  let help: String
  let action: () -> Void
}

/// The shell shared by the composer's run-target pickers (machine, project,
/// run location): a `PickerChip` that opens an Autocomplete popup laid out
/// like the menus it replaces — a check column marking the current choice,
/// an icon on every row, a search field, the caller's rows, and one pinned
/// footer action — presented the way the model picker is.
struct RunPickerMenu<Target: Hashable, Rows: View>: View {
  let chipText: String
  let chipSymbol: String
  /// The unfiltered row titles. The popup is sized to fit all of them so
  /// filtering never resizes it.
  let titles: [String]
  let searchAccessibilityLabel: String
  let footer: RunPickerFooter<Target>
  @ViewBuilder let rows: (RunPickerContext) -> Rows

  @State private var isPresented = false
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<Target>(navigation: .menu)

  private static var metrics: Autocomplete.Metrics { Autocomplete.Style.xcodeMenu.metrics }

  var body: some View {
    Button {
      query = ""
      isPresented.toggle()
    } label: {
      PickerChip(text: chipText) {
        Image(systemName: chipSymbol)
          .font(.system(size: 12))
      }
    }
    .buttonStyle(HoverIconButtonStyle(shape: .chip))
    .fixedSize()
    .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      popup
    }
  }

  private var popup: some View {
    let metrics = Self.metrics
    let context = RunPickerContext(query: query.trimmingCharacters(in: .whitespacesAndNewlines), dismiss: dismiss)
    return Autocomplete.Root(highlight: highlight, showsCheckmarks: true, showsIcons: true, onDismiss: dismiss) {
      Autocomplete.Input(
        text: $query, prompt: "Search", accessibilityLabel: searchAccessibilityLabel, focusesOnAppear: true
      )
      Autocomplete.List(height: metrics.listHeight(itemCount: titles.count, footerItemCount: 1)) {
        rows(context)
      }
      Autocomplete.Footer {
        Autocomplete.Item(id: footer.id, icon: Image(systemName: footer.symbol), action: runFooterAction) { _ in
          Text(footer.title)
        }
        .help(footer.help)
      }
    }
    .frame(width: metrics.popupWidth(fitting: titles + [footer.title], hasIcons: true, showsCheckmarks: true))
  }

  private func dismiss() {
    isPresented = false
  }

  private func runFooterAction() {
    dismiss()
    footer.action()
  }
}
