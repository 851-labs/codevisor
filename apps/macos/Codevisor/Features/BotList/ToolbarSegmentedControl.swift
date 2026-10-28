import AppKit

final class ToolbarSegmentedControl: NSSegmentedControl {
  private static let setSemanticContext = Selector(("_setSemanticContext:"))
  private static let toolbarSemanticContext = 4

  convenience init(titles: [String], target: AnyObject, action: Selector) {
    self.init(labels: titles, trackingMode: .selectOne, target: target, action: action)
    controlSize = .extraLarge
    adoptToolbarRendering()
  }

  private func adoptToolbarRendering() {
    guard responds(to: Self.setSemanticContext) else { return }

    typealias SetContext = @convention(c) (NSView, Selector, Int) -> Void
    let setContext = unsafeBitCast(method(for: Self.setSemanticContext), to: SetContext.self)
    setContext(self, Self.setSemanticContext, Self.toolbarSemanticContext)
  }
}
