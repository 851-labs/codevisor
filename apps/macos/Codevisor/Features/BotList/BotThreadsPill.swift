import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotThreadsPillContent: Equatable {
  let bot: Bot
  let threads: [ServerThread]

  var title: String {
    threads.count == 1 ? "1 Thread" : "\(threads.count) Threads"
  }
}

struct BotThreadsPill: View {
  let content: BotThreadsPillContent
  let glassNamespace: Namespace.ID
  @Environment(AppEnvironment.self) private var environment
  @State private var isShowingThreads = false

  var body: some View {
    Button {
      isShowingThreads.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "bubble.left.and.bubble.right")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(content.title)
          .monospacedDigit()
      }
      .fixedSize()
    }
    .buttonStyle(ChildAgentsPillButtonStyle())
    .composerGlassSurface(shape: Capsule(), id: .threads, in: glassNamespace)
    .popover(isPresented: $isShowingThreads, arrowEdge: .top) {
      BotThreadsPopover(content: content) { thread in
        isShowingThreads = false
        environment.botThreads.openThreadByBot[content.bot.id] = thread.threadId
      }
    }
    .help("Show this bot's threads with other bots and agents")
    .accessibilityLabel(content.title)
  }
}

private struct BotThreadsPopover: View {
  let content: BotThreadsPillContent
  let open: (ServerThread) -> Void
  @Environment(AppEnvironment.self) private var environment

  private static let width: CGFloat = 300
  private static let maxHeight: CGFloat = 380

  var body: some View {
    ViewThatFits(in: .vertical) {
      rows
      ScrollView { rows }
    }
    .frame(maxHeight: Self.maxHeight)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: Self.width)
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(content.threads) { thread in
        if let other = environment.botThreads.other(in: thread, than: content.bot) {
          BotThreadRow(participant: other, preview: thread.lastMessage) {
            open(thread)
          }
        }
      }
    }
    .padding(8)
  }
}

private struct BotThreadRow: View {
  let participant: ServerThreadParticipant
  let preview: ServerThreadMessage?
  let open: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        ThreadParticipantAvatar(participant: participant, size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(participant.threadDisplayName)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
          if let preview {
            Text("\(preview.from.threadDisplayName): \(preview.text)")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? Color.primary.opacity(0.06) : .clear)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityLabel("Thread with \(participant.threadDisplayName)")
  }
}
