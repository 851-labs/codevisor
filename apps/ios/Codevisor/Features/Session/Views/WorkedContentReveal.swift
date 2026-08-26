import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkedContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: TranscriptDisclosureStore.Key
    let store: TranscriptDisclosureStore
    let revealGeneration: Int
    let presentationKey: String?
    @State private var isVisible: Bool
    private let content: Content

    init(
        key: TranscriptDisclosureStore.Key,
        store: TranscriptDisclosureStore,
        presentationKey: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.key = key
        self.store = store
        self.presentationKey = presentationKey
        let generation = store.revealGeneration(for: key)
        revealGeneration = generation
        _isVisible = State(
            initialValue: !store.hasUnclaimedReveal(
                key,
                generation: generation,
                presentationKey: presentationKey
            )
        )
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : -8)
            .onAppear {
                let shouldAnimate = store.claimReveal(
                    key,
                    generation: revealGeneration,
                    presentationKey: presentationKey
                )
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
