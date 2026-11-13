import SwiftUI

struct OpenBotThread {
  let botName: String
  let close: () -> Void
}

struct BotThreadBackButton: View {
  let thread: OpenBotThread

  var body: some View {
    Button(action: thread.close) {
      Label("Back to \(thread.botName)", systemImage: "chevron.backward")
    }
    .labelStyle(.iconOnly)
    .help("Back to your conversation with \(thread.botName)")
    .keyboardShortcut(.cancelAction)
  }
}
