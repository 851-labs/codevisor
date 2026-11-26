import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceDeck<Page: View>: View {
  let navigation: WindowNavigation
  @ViewBuilder let page: (WorkspaceDeckRoute) -> Page

  var body: some View {
    let deck = navigation.deck
    let sizes = navigation.deckSizes
    WorkspaceDeckLayout {
      ForEach(deck.pages) { mounted in
        let isActive = mounted.id == deck.activeSlot
        let frozenSize = isActive ? nil : sizes.frozenSize(for: mounted.id)
        WorkspaceDeckPage(
          route: mounted.route, activity: deck.activity(for: mounted.id), model: navigation.page(for: mounted.id)
        ) {
          page(mounted.route)
        }
        .equatable()
        .environment(\.reusesChatPage, mounted.id == .sharedChat)
        .frame(width: frozenSize?.width, height: frozenSize?.height)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
      }
    }
    .environment(\.detailColumnFocus, navigation.detailFocus)
    .onGeometryChange(for: CGSize.self, of: \.size) { sizes.current = $0 }
    .background(DetailColumnFocusAnchor.Capture(anchor: navigation.detailFocus).frame(width: 0, height: 0))
    .onChange(of: navigation.deckSlot, initial: true) { _, _ in navigation.showDeckPage() }
  }
}
