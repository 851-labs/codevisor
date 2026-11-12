import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeBlankPage<CodePage: View>: View {
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  let onNewBot: () -> Void
  @ViewBuilder let codePage: () -> CodePage

  var body: some View {
    if storedMode == .bots {
      BotListEmptyDetail(onNewBot: onNewBot)
    } else {
      codePage()
    }
  }
}
