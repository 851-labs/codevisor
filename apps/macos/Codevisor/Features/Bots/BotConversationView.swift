import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationView: View {
  let bot: Bot
  let client: any CodevisorServerClienting

  @State private var model: BotConversationModel?

  var body: some View {
    Group {
      if let model {
        BotConversationContent(model: model, bot: bot)
      } else {
        Color.clear
      }
    }
    .task(id: bot.sessionId) {
      self.model?.stop()
      let model = BotConversationModel(sessionId: bot.sessionId, client: client)
      self.model = model
      model.start()
    }
    .onDisappear {
      model?.stop()
      model = nil
    }
  }
}

private struct BotConversationContent: View {
  let model: BotConversationModel
  let bot: Bot

  @State private var isNearBottom = true
  @State private var draft = ""
  @State private var attachments: [ServerAttachmentRef] = []
  @State private var uploadingCount = 0
  @State private var uploadError: String?
  @FocusState private var composerFocused: Bool

  private static let bottomAnchor = "bot.conversation.bottom"

  var body: some View {
    VStack(spacing: 0) {
      transcript
      composer
    }
    .background(Color(nsColor: .textBackgroundColor))
    .onAppear { composerFocused = true }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if model.hasMore {
            ProgressView()
              .controlSize(.small)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
              .onAppear { Task { await model.loadOlder() } }
          }
          if model.hasLoaded, model.rows.isEmpty, !model.isWorking {
            emptyState
          }
          ForEach(model.rows) { row in
            switch row {
            case let .timestamp(date):
              BotTimestampRow(date: date)
            case let .notice(entry):
              BotNoticeRow(text: entry.message.text)
            case let .message(entry):
              BotMessageBubble(entry: entry) {
                Task { await model.retry(entry.id) }
              }
            }
          }
          if model.isWorking {
            BotTypingIndicator()
              .transition(.opacity)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchor)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .animation(.easeOut(duration: 0.18), value: model.isWorking)
      }
      .defaultScrollAnchor(.bottom)
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentSize.height - geometry.visibleRect.maxY < 80
      } action: { _, nearBottom in
        isNearBottom = nearBottom
      }
      .onChange(of: model.lastMessageId) { _, _ in
        guard isNearBottom else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
      }
      .onChange(of: model.isWorking) { _, _ in
        guard isNearBottom else { return }
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
      }
      .accessibilityIdentifier("bot.conversation")
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: bot.symbolName)
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text(bot.name)
        .font(.title3.weight(.semibold))
      Text("Send a message to get started.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 80)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !attachments.isEmpty || uploadingCount > 0 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              BotComposerAttachmentChip(name: attachment.name) {
                attachments.removeAll { $0.fileId == attachment.fileId }
              }
            }
            if uploadingCount > 0 {
              ProgressView().controlSize(.small)
            }
          }
        }
      }
      if let uploadError {
        Text(uploadError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack(alignment: .bottom, spacing: 8) {
        Button(action: pickAttachments) {
          Image(systemName: "paperclip")
            .font(.system(size: 15, weight: .medium))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Attach Files")
        .accessibilityLabel("Attach Files")
        .accessibilityIdentifier("bot.composer.attach")

        TextField("Message \(bot.name)", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.body)
          .lineLimit(1...8)
          .focused($composerFocused)
          .onSubmit(send)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
              .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
          )
          .accessibilityIdentifier("bot.composer.text")

        Button(action: send) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 26))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, canSend ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send")
        .accessibilityLabel("Send")
        .accessibilityIdentifier("bot.composer.send")
      }
    }
    .frame(maxWidth: 760)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 14)
    .overlay(alignment: .top) {
      Color.separatorColor.frame(height: 1)
    }
  }

  private var canSend: Bool {
    uploadingCount == 0
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }

  private func send() {
    guard canSend else { return }
    let text = draft
    let files = attachments
    draft = ""
    attachments = []
    uploadError = nil
    Task { await model.send(text, attachments: files) }
  }

  private func pickAttachments() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { upload(url) }
  }

  private func upload(_ url: URL) {
    uploadingCount += 1
    Task {
      defer { uploadingCount -= 1 }
      do {
        attachments.append(try await model.upload(url))
      } catch {
        uploadError = "Couldn’t attach “\(url.lastPathComponent)”."
      }
    }
  }
}

private struct BotComposerAttachmentChip: View {
  let name: String
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "doc")
        .foregroundStyle(.secondary)
      Text(name)
        .lineLimit(1)
        .truncationMode(.middle)
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(name)")
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: 220)
    .background(Capsule().fill(Color.bubbleBackground))
  }
}
