import AppKit
import Foundation
import Testing
@testable import StreamMarkdown

/// Streams a real assistant answer (two paragraphs then a bulleted list with
/// inline code) token by token through the same parse → render → reconcile
/// pipeline the transcript uses, and asserts that a word which has become
/// visible is never scheduled to fade in again.
@MainActor
@Suite("Streaming list reveal regression")
struct StreamingListRevealRegressionTests {
  private static let message = """
    This repo is Codevisor, a native macOS and iOS client for running and managing coding agents such as Claude Code, Codex, Pi, Cursor, and other ACP-compatible agents.

    Its main pieces are:
    - `apps/macos` — native Swift macOS app with terminal, project/workspace management, agent chats, remote machines, plugins, and updates.
    - `apps/ios` — iOS companion client for viewing and interacting with machines and agent sessions.
    - `apps/server` — local server/CLI installed on developer machines. It manages agent processes, terminals, worktrees, MCP, and machine connections.
    - `apps/cloud` — Cloudflare Worker backend providing authentication and an end-to-end encrypted WebSocket relay between apps and machines.
    - `packages/*` — shared TypeScript and Swift libraries for agent adapters, APIs, databases, encryption, synchronization, plugins, terminals, worktrees, and UI.
    """

  /// Token-ish slices: a few characters at a time, with list markers landing
  /// on their own so the "- " → empty item → text sequence is exercised.
  private static func slices(of text: String) -> [String] {
    var result: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if current.count >= 4 || character == "\n" || character == " " {
        result.append(current)
        current = ""
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  @Test("Visible words are never hidden again while a list streams")
  func visibleWordsStayVisible() {
    let parser = MarkdownParser()
    let timeline = StreamingTextAnimationTimeline()
    let state = StreamingTextAnimationState()
    let theme = MarkdownTheme()
    var document = ""
    var now: TimeInterval = 10
    var visibleWords: [String: TimeInterval] = [:]
    var failures: [String] = []

    for slice in Self.slices(of: Self.message) {
      document += slice
      now += 0.03
      let blocks = parser.parse(document)
      guard MarkdownTextRunRenderer.canRenderFlattenedText(blocks) else {
        failures.append("blocks not text-run compatible at \(document.count) chars: \(blocks.map(\.id))")
        break
      }
      let rendered = MarkdownTextRunRenderer.attributedString(
        for: blocks,
        theme: theme,
        foregroundColor: theme.textForeground
      )
      let prepared = state.prepare(
        rendered,
        context: StreamingTextAnimationContext(
          timeline: timeline,
          sourceID: "row-0",
          documentSource: document,
          isStreaming: true,
          animatesInitialContent: true,
          reduceMotion: false
        ),
        now: now
      )
      // Anything whose fade already ended (or that carries no fade) is
      // visible. Record it by position; a later pass must not attach a
      // fade with a future start to the same position.
      let string = prepared.text.string as NSString
      for segment in StreamingWordSegmenter.segments(in: prepared.text.string) {
        let fade =
          prepared.text.attribute(
            .streamMarkdownFade, at: segment.range.location, effectiveRange: nil
          ) as? StreamingTextFadeMetadata
        let key = "\(segment.range.location):\(string.substring(with: segment.range).prefix(12))"
        let opacity = fade?.opacity(at: now) ?? 1
        if opacity >= 1 {
          visibleWords[key] = now
        } else if let seenAt = visibleWords[key] {
          failures.append(
            "word \(key) was visible at \(seenAt) but hidden again at \(now) (opacity \(opacity), start \(fade?.startTime ?? -1)); doc \(document.count) chars"
          )
        }
      }
      // Let every scheduled fade finish before the next token so each
      // pass starts from a fully visible surface.
      now += 5
      if failures.count > 3 { break }
    }

    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
  }
}
