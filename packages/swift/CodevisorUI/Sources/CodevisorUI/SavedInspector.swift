import SwiftUI

public struct SavedInspector<Column: View>: ViewModifier {
  private let isShown: Bool
  private let savedIsShown: () -> Bool
  private let close: () -> Void
  private let column: Column
  @State private var columnShown: Bool
  @State private var reverting = false

  public init(
    isShown: Bool, savedIsShown: @escaping () -> Bool, close: @escaping () -> Void,
    @ViewBuilder column: () -> Column
  ) {
    self.isShown = isShown
    self.savedIsShown = savedIsShown
    self.close = close
    self.column = column()
    _columnShown = State(initialValue: isShown)
  }

  public func body(content: Content) -> some View {
    content
      .inspector(isPresented: savedColumn.binding) { column }
      .onChange(of: isShown) { _, shown in
        reverting = false
        columnShown = shown
      }
      .onChange(of: columnShown) { _, shown in
        if shown, !isShown { columnShown = false }
      }
  }

  private var savedColumn: SavedInspectorColumn {
    SavedInspectorColumn(
      isShown: columnShown, savedIsShown: savedIsShown, close: closeColumn, revert: revertColumn,
      settle: { reverting = false })
  }

  private func closeColumn() {
    columnShown = false
    close()
  }

  private func revertColumn() {
    guard !reverting else { return }

    reverting = true
    columnShown = true
  }
}
