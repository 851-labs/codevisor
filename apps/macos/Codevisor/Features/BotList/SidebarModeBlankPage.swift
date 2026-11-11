import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeBlankPage<CodePage: View>: View {
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  let onNewBot: () -> Void
  @ViewBuilder let codePage: () -> CodePage

  var body: some View {
    if SidebarMode.active(storedMode, botsEnabled: botsEnabled) == .bots {
      BotListEmptyDetail(onNewBot: onNewBot)
    } else {
      codePage()
    }
  }
}
