import SwiftUI

struct PromotedHorizontalSafeAreaExpansion: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.ignoresSafeArea(.container, edges: .horizontal)
        } else {
            content
        }
    }
}
