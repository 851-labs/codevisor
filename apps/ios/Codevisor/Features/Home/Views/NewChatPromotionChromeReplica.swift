import SwiftUI

/// The first-send expansion's replica: the route's navigation chrome over
/// a flat background, and nothing else. The sheet's bitmap covers the
/// content until Home's canonical route takes over at commit, so all the
/// expansion ever reveals of this view is the bar area — the back chevron
/// and the trailing button the sheet's × morphs into. It carries no
/// session identity, so it mounts while the sheet is still being composed
/// and costs the send nothing.
struct NewChatPromotionChromeReplica: View {
  let flow: NewChatFlow
  let root: AnyView

  var body: some View {
    // At destination depth from the start, so the chrome (including the
    // system back button) is exactly the canonical route's.
    NavigationStack(path: .constant([NewChatPromotionRoute.workspace])) {
      root
        .navigationDestination(for: NewChatPromotionRoute.self) { _ in
          Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .topBarTrailing) {
                NewChatPromotionTrailingButton(flow: flow)
              }
            }
        }
    }
  }
}

/// One button whose glyph swaps with a symbol morph inside the same glass
/// circle, so the control never jumps: the sheet's × until the expansion
/// begins, the route's + from then on.
private struct NewChatPromotionTrailingButton: View {
  let flow: NewChatFlow

  var body: some View {
    let showsCompose = !flow.hasStartedExpansion
    Button {
      // Replica only: never interactive.
    } label: {
      Image(systemName: showsCompose ? "xmark" : "plus")
        // Magic replace morphs the shared strokes in one pass. The
        // two-phase variants pause on a dot between phases whenever the
        // main thread is busy, which it always is right here.
        .contentTransition(.symbolEffect(.replace.magic(fallback: .offUp)))
    }
    .accessibilityHidden(true)
  }
}
