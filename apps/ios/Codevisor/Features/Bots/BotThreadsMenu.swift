import CodevisorCore
import SwiftUI

struct BotThreadsMenu: View {
  let bot: Bot
  let threads: [ServerThread]
  let open: (ServerThread) -> Void
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    Menu {
      Section("Threads") {
        ForEach(threads) { thread in
          Button {
            open(thread)
          } label: {
            Text(name(of: thread))
            if let preview = thread.lastMessage {
              Text("\(preview.from.threadDisplayName): \(preview.text)")
            }
          }
        }
      }
    } label: {
      Image(systemName: "bubble.left.and.bubble.right")
    }
    .accessibilityLabel(threads.count == 1 ? "1 thread" : "\(threads.count) threads")
    .accessibilityIdentifier("bot.threads")
  }

  private func name(of thread: ServerThread) -> String {
    environment.botThreads.other(in: thread, than: bot)?.threadDisplayName ?? "Agent"
  }
}
