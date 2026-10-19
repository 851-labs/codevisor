#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI
  import UIKit

  @MainActor
  @Observable
  public final class TextSelectionSession {
    public private(set) var isActive = false
    @ObservationIgnored private let members = NSHashTable<SelectableTextKitView>.weakObjects()

    public init() {}

    public func begin() {
      guard !isActive else { return }
      isActive = true
      let views = members.allObjects
      for view in views { view.isSelectable = true }
      views.filter { $0.window != nil }.min(by: Self.readsBefore)?.focusSelection()
    }

    public func end() {
      guard isActive else { return }
      isActive = false
      for view in members.allObjects { view.isSelectable = false }
    }

    func join(_ view: SelectableTextKitView) {
      members.add(view)
    }

    func leave(_ view: SelectableTextKitView) {
      members.remove(view)
    }

    func memberResigned() {
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.members.allObjects.contains(where: \.isFirstResponder) else { return }
        self.end()
      }
    }

    private static func readsBefore(_ lhs: UIView, _ rhs: UIView) -> Bool {
      let left = lhs.convert(CGPoint.zero, to: nil)
      let right = rhs.convert(CGPoint.zero, to: nil)
      return left.y == right.y ? left.x < right.x : left.y < right.y
    }
  }

  extension EnvironmentValues {
    @Entry public var textSelectionSession: TextSelectionSession? = nil
  }
#endif
