import AppKit
import Observation
import StreamMarkdown
import SwiftUI
import Testing
@testable import TranscriptSurface

@Suite("Native prepared content", .serialized)
@MainActor
struct TranscriptPreparedContentTests {
  @Observable
  final class Content {
    var isPrepared = false
  }

  @Test("Replacing a root while preparation is pending preserves its readiness", arguments: [false, true])
  func rootReplacementDuringPreparation(usesCachedHeight: Bool) async throws {
    _ = NSApplication.shared
    let host = TranscriptRowHost(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    let content = Content()
    let (readiness, continuation) = AsyncStream<Bool>.makeStream()
    defer {
      continuation.finish()
      window.contentView = nil
    }
    var reportedHeight: CGFloat = 0
    host.onHeightChange = { reportedHeight = $0 }
    func root() -> AnyView {
      AnyView(
        PreparedFixture(content: content)
          .onPreferenceChange(ContentLayoutReadinessPreferenceKey.self) { unresolved in
            host.setAttachmentGeometryReady(unresolved == 0)
            continuation.yield(unresolved == 0)
          }
          .frame(width: 800, alignment: .topLeading)
          .id("prepared-row")
      )
    }
    host.syncContentWidth()
    host.installRootView(root(), knownHeight: nil)
    host.prepareForImmediatePresentation()
    var updates = readiness.makeAsyncIterator()
    #expect(await updates.next() == false)
    host.installRootView(root(), knownHeight: usesCachedHeight ? 320 : nil)
    host.prepareForImmediatePresentation()
    #expect(!host.isAttachmentGeometryReady)
    content.isPrepared = true
    #expect(await updates.next() == true)
    host.prepareForImmediatePresentation()
    #expect(reportedHeight == 1_200)
  }

  private struct PreparedFixture: View {
    let content: Content
    var body: some View {
      Color.clear.frame(height: content.isPrepared ? 1_200 : 320)
        .preference(key: ContentLayoutReadinessPreferenceKey.self, value: content.isPrepared ? 0 : 1)
    }
  }

  @Test("A prepared paragraph replaces its placeholder height")
  func preparedParagraphReportsItsNaturalHeight() async throws {
    _ = NSApplication.shared
    let host = TranscriptRowHost(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    let (readiness, continuation) = AsyncStream<Bool>.makeStream()
    defer {
      continuation.finish()
      window.contentView = nil
    }
    var reportedHeight: CGFloat = 0
    host.onHeightChange = { reportedHeight = $0 }
    host.syncContentWidth()
    host.installRootView(
      AnyView(
        StreamingMarkdownView(String(repeating: "A paragraph **with styling** and 日本語. ", count: 500))
          .environment(\.streamMarkdownTextLayoutWidth, 800)
          .onPreferenceChange(ContentLayoutReadinessPreferenceKey.self) { unresolved in
            host.setAttachmentGeometryReady(unresolved == 0)
            continuation.yield(unresolved == 0)
          }
          .frame(width: 800, alignment: .topLeading)
      ), knownHeight: nil
    )
    host.prepareForImmediatePresentation()
    var observedPreparation = false
    for await ready in readiness {
      if !ready { observedPreparation = true }
      if ready && observedPreparation { break }
    }
    host.prepareForImmediatePresentation()
    #expect(reportedHeight > 320)
  }
}
