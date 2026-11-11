import CodevisorUI
import SwiftUI

struct SettingsAddMenu<Items: View>: View {
  let title: String
  let items: () -> Items
  @State private var anchor = SettingsMenuAnchor()

  init(_ title: String, @ViewBuilder items: @escaping () -> Items) {
    self.title = title
    self.items = items
  }

  var body: some View {
    SettingsAddButton(title) { anchor.popUp(NSHostingMenu(rootView: items())) }
      .background(SettingsMenuAnchorView(anchor: anchor))
  }
}
