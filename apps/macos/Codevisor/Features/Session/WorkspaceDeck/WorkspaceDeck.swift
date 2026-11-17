import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceDeck<Page: View>: View {
  let navigation: WindowNavigation
  @ViewBuilder let page: (WorkspaceDeckRoute) -> Page
  @State private var focusAnchor = DetailColumnFocusAnchor()

  var body: some View {
    let deck = navigation.deck
    let sizes = navigation.deckSizes
    WorkspaceDeckLayout {
      ForEach(deck.pages) { mounted in
        let isActive = mounted.id == deck.activeSlot
        let frozenSize = isActive ? nil : sizes.frozenSize(for: mounted.id)
        WorkspaceDeckPage(route: mounted.route, activity: deck.activity(for: mounted.id)) {
          page(mounted.route)
        }
        .equatable()
        .frame(width: frozenSize?.width, height: frozenSize?.height)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
      }
    }
    .onGeometryChange(for: CGSize.self, of: \.size) { sizes.current = $0 }
    .background(DetailColumnFocusAnchor.Capture(anchor: focusAnchor).frame(width: 0, height: 0))
    .onChange(of: navigation.deckSlot, initial: true) { _, slot in
      navigation.showDeckPage()
      if slot != nil { focusAnchor.releaseFocus() }
    }
  }
}
