import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotListEmptyDetail: View {
  @Environment(AppEnvironment.self) private var environment
  let onNewBot: () -> Void

  var body: some View {
    if availability.hasBots {
      BotNotSelectedDetail(onNewBot: onNewBot)
    } else {
      noBots
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
  }

  private var noBots: some View {
    ZStack {
      if availability.hasLoaded {
        BotsEmptyState(onNewBot: onNewBot)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var availability: BotListAvailability {
    BotListAvailability(environment: environment)
  }
}
