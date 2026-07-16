import SwiftUI

/// Shared Liquid Glass treatment for the functional surfaces clustered around
/// the composer. Keeping the material and geometry here prevents pinned
/// controls from drifting back to opaque, independently styled cards.
enum ComposerGlassStyle {
    static let composerCornerRadius: CGFloat = 16
    static let accessoryCornerRadius: CGFloat = 12
    static let clusterSpacing: CGFloat = 8
}

extension View {
    func composerGlassSurface(cornerRadius: CGFloat) -> some View {
        glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius)
        )
    }
}
