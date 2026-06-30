import Foundation

/// Which input area should hold keyboard focus in a session screen.
public enum SessionFocusTarget: Sendable, Equatable {
    case composer
    case terminal
}

/// The per-session terminal panel's UI state: whether it's open and how tall it
/// is. Pure value type so the visibility/resize/focus rules are unit-testable
/// without any AppKit or libghostty involvement.
public struct TerminalPanelState: Sendable, Equatable {
    /// Default panel height when first opened.
    public static let defaultHeight: CGFloat = 280
    /// Clamp bounds for the drag-to-resize handle.
    public static let minHeight: CGFloat = 120
    public static let maxHeight: CGFloat = 800

    public var isVisible: Bool
    public var height: CGFloat

    public init(isVisible: Bool = false, height: CGFloat = TerminalPanelState.defaultHeight) {
        self.isVisible = isVisible
        self.height = Self.clampHeight(height)
    }

    /// Toggles visibility and returns the area that should receive focus:
    /// opening focuses the terminal, closing returns focus to the composer.
    @discardableResult
    public mutating func toggle() -> SessionFocusTarget {
        isVisible.toggle()
        return isVisible ? .terminal : .composer
    }

    /// Sets the panel height, clamped to `[minHeight, maxHeight]`.
    public mutating func setHeight(_ newHeight: CGFloat) {
        height = Self.clampHeight(newHeight)
    }

    private static func clampHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, minHeight), maxHeight)
    }
}
