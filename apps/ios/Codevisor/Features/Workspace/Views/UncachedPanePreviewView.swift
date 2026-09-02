import CodevisorCore
import CodevisorUI
import SwiftUI

/// A fixed-canvas bridge for a pane that has never produced a real preview.
/// Its symbol is positioned so the card endpoint exactly matches the grid's
/// centered placeholder. The canvas then expands uniformly—without a blank
/// frame or instant state change—and dissolves into live UI only at the full
/// pane endpoint.
struct UncachedPanePreviewView: View {
  let kind: PaneKind
  let canvasSize: CGSize
  let sourceCardSize: CGSize

  private var symbolName: String {
    switch kind {
    case .terminal: "terminal"
    case .chat: "bubble.left.and.bubble.right"
    case .newTab: "plus.square.on.square"
    case .plugin: "puzzlepiece.extension"
    }
  }

  private var background: Color {
    kind == .terminal ? .black : Color(.secondarySystemGroupedBackground)
  }

  private var symbolColor: Color {
    kind == .terminal ? .white.opacity(0.6) : .secondary
  }

  private var symbolCenterY: CGFloat {
    WorkspaceTabZoomTransitionContract.uncachedPlaceholderSymbolCenterY(
      canvasSize: canvasSize,
      cardSize: sourceCardSize
    ) ?? canvasSize.height / 2
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      background
      Image(systemName: symbolName)
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(symbolColor)
        .position(x: canvasSize.width / 2, y: symbolCenterY)
    }
    .frame(width: canvasSize.width, height: canvasSize.height)
  }
}
