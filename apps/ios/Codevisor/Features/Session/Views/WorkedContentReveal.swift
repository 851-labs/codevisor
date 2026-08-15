import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkedContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: TranscriptDisclosureStore.Key
    let store: TranscriptDisclosureStore
    let revealGeneration: Int
    @State private var isVisible: Bool
    private let content: Content

    init(
        key: TranscriptDisclosureStore.Key,
        store: TranscriptDisclosureStore,
        @ViewBuilder content: () -> Content
    ) {
        self.key = key
        self.store = store
        let generation = store.revealGeneration(for: key)
        revealGeneration = generation
        _isVisible = State(
            initialValue: !store.hasUnclaimedReveal(key, generation: generation)
        )
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : -8)
            .onAppear {
                let shouldAnimate = store.claimReveal(key, generation: revealGeneration)
                guard shouldAnimate, !reduceMotion else {
                    isVisible = true
                    return
                }
                withAnimation(Motion.entrance()) {
                    isVisible = true
                }
            }
    }
}
