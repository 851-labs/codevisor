import CodevisorUI
import SwiftUI

struct BotListPlaceholder: View {
  var body: some View {
    VStack(spacing: 6) {
      Text(BotListEmptyCopy.title)
        .font(.headline)
      Text(BotListEmptyCopy.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
