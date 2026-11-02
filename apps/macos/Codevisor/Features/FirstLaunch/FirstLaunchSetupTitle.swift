import SwiftUI

struct FirstLaunchSetupTitle: View {
  let isFinished: Bool

  static let settingUp = "Getting things set up"

  var body: some View {
    ZStack {
      Text(Self.settingUp)
        .opacity(isFinished ? 0 : 1)
      Text("You're all set")
        .opacity(isFinished ? 1 : 0)
    }
    .font(.title2.weight(.semibold))
    .lineLimit(1)
    .animation(.smooth(duration: 0.3), value: isFinished)
  }
}
