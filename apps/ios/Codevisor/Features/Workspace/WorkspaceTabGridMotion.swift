import SwiftUI

/// Motion shared by every in-grid mutation. The lifted preview and the empty
/// slot are separate layers, so these springs never stretch or reflow card
/// contents.
enum WorkspaceTabGridMotion {
    static let lift = Animation.interactiveSpring(
        response: 0.18,
        dampingFraction: 0.88,
        blendDuration: 0.03
    )
    static let reorder = Animation.interactiveSpring(
        response: 0.24,
        dampingFraction: 0.86,
        blendDuration: 0.06
    )
    static let removal = Animation.interactiveSpring(
        response: 0.28,
        dampingFraction: 0.9,
        blendDuration: 0.04
    )
    static let release = Animation.interactiveSpring(
        response: 0.3,
        dampingFraction: 0.88,
        blendDuration: 0.05
    )
}
