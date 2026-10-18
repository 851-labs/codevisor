import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

enum BotMarkdownBlock: Equatable {
  case text(String)
  case code(String)

  static func parse(_ markdown: String) -> [BotMarkdownBlock] {
    var blocks: [BotMarkdownBlock] = []
    var prose: [String] = []
    var code: [String]?
    func flushProse() {
      let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
      if !text.isEmpty { blocks.append(.text(text)) }
      prose.removeAll()
    }
    for line in markdown.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if let open = code {
          blocks.append(.code(open.joined(separator: "\n")))
          code = nil
        } else {
          flushProse()
          code = []
        }
        continue
      }
      if code != nil {
        code?.append(line)
      } else {
        prose.append(listLine(line))
      }
    }
    if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
    flushProse()
    return blocks
  }

  private static func listLine(_ line: String) -> String {
    let indent = line.prefix { $0 == " " }
    let rest = line.dropFirst(indent.count)
    guard rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") else { return line }
    return "\(indent)• \(rest.dropFirst(2))"
  }

  static func inline(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }
}

struct BotMessageBubble: View {
  let entry: BotConversationEntry
  var onRetry: () -> Void = {}
  @State private var isHovered = false

  private var isUser: Bool { entry.sender == .user }

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      if isUser { Spacer(minLength: 80) }
      VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
        if let attachments = entry.message.attachments, !attachments.isEmpty {
          attachmentStack(attachments)
        }
        if !entry.message.text.isEmpty {
          bubble
        }
        if entry.delivery == .failed {
          Button(action: onRetry) {
            Label("Not Delivered — Retry", systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(.red)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("bot.message.retry")
        }
      }
      if !isUser { Spacer(minLength: 80) }
    }
    .padding(.top, entry.startsGroup ? 8 : 0)
    .hoverTracking($isHovered, respectsSuspension: false)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(isUser ? "bot.message.user" : "bot.message.bot")
    .accessibilityActions {
      if !entry.message.text.isEmpty {
        Button("Copy Message") { PlatformPasteboard.copy(entry.message.text) }
      }
    }
  }

  private var bubble: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(BotMarkdownBlock.parse(entry.message.text).enumerated()), id: \.offset) { _, block in
        switch block {
        case let .text(text):
          Text(BotMarkdownBlock.inline(text))
            .font(.body)
            .tint(isUser ? .white : .accentColor)
            .fixedSize(horizontal: false, vertical: true)
        case let .code(code):
          ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
              .font(.system(.callout, design: .monospaced))
              .fixedSize()
              .padding(8)
          }
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(isUser ? Color.white.opacity(0.16) : Color.primary.opacity(0.06))
          )
        }
      }
    }
    .textSelection(.enabled)
    .foregroundStyle(isUser ? Color.white : Color.primary)
    .padding(.horizontal, TranscriptSendFlightGeometry.bubbleTextInsets.horizontal)
    .padding(.vertical, TranscriptSendFlightGeometry.bubbleTextInsets.vertical)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(isUser ? Color.accentColor : Color.bubbleBackground)
    )
    .opacity(entry.delivery == .sending ? 0.7 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bot.message.bubble")
  }

  private func attachmentStack(_ attachments: [ServerAttachmentRef]) -> some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
      ForEach(attachments) { attachment in
        AttachmentThumbnailView(attachment: attachment.attachment, inline: true)
      }
    }
  }
}

struct BotNoticeRow: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .accessibilityIdentifier("bot.message.notice")
  }
}

struct BotTimestampRow: View {
  let date: Date

  var body: some View {
    Text(Self.label(for: date))
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
      .padding(.bottom, 2)
  }

  static func label(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return "Today \(date.formatted(date: .omitted, time: .shortened))"
    }
    if calendar.isDateInYesterday(date) {
      return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}

struct BotTypingIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack {
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
        let phase = context.date.timeIntervalSinceReferenceDate
        HStack(spacing: 4) {
          ForEach(0..<3, id: \.self) { index in
            Circle()
              .fill(Color.secondary)
              .frame(width: 7, height: 7)
              .opacity(reduceMotion ? 0.6 : 0.35 + 0.65 * Self.pulse(phase: phase, index: index))
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.bubbleBackground)
        )
      }
      Spacer()
    }
    .padding(.top, 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Bot is working")
    .accessibilityIdentifier("bot.typingIndicator")
  }

  private static func pulse(phase: TimeInterval, index: Int) -> Double {
    let value = sin((phase * 2 * .pi / 1.2) - Double(index) * 0.7)
    return max(0, value)
  }
}
