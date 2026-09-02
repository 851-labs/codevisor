// Generic transcript disclosure chrome, shared by tool rows, worked sections,
// setup phases, and message roots on both platforms.
import SwiftUI

/// Commits disclosure layout at its final size, then animates only the newly
/// revealed pixels. This is the same presentation model as the original
/// "Worked for…" disclosure: the virtualizer receives one authoritative row
/// height rather than following an intermediate height animation.
public struct TranscriptDisclosureContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
    let isExpanded: Bool
    @State private var isVisible: Bool
    private let content: Content

    public init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        _isVisible = State(initialValue: isExpanded)
        self.content = content()
    }

    public var body: some View {
        Group {
            if isExpanded {
                content
                    .opacity(isVisible || reduceMotion ? 1 : 0)
                    .offset(y: isVisible || reduceMotion ? 0 : -8)
                    .onAppear {
                        revealIfNeeded()
                    }
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                // The shared reveal remains mounted while its content does
                // not, so the next false-to-true transition starts hidden.
                isVisible = false
            }
            // The Boolean change inserts/removes the final-size content in one
            // SwiftUI commit. Native row hosts defer this request until that
            // commit is laid out, then report the one resulting height.
            invalidateRowMeasurement?()
        }
    }

    private func revealIfNeeded() {
        guard !isVisible else { return }
        guard !reduceMotion else {
            isVisible = true
            return
        }
        withAnimation(Motion.entrance()) {
            isVisible = true
        }
    }
}
