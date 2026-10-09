import AppKit
import CodevisorUI
import Observation
import StreamMarkdown
import SwiftUI
import Testing
import TranscriptKit
@testable import CodevisorCore
@testable import TranscriptSurface

@Suite("Follow-up transcript activity")
@MainActor
struct TranscriptFollowUpActivityTests {
  @Test("Thinking remains visible after a follow-up's native send animation completes", .timeLimit(.minutes(1)))
  func quietFollowUpAfterSendCompletion() async throws {
    let fixture = ActivityFixture()
    defer { fixture.tearDown() }
    let options = TranscriptProjectionOptions(includesConnectingRow: false, bottomSpacerHeight: 100)
    let firstPrompt = UserMessage(text: "First message")
    let completed = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "answer", markdown: "First answer")]))
    fixture.model.applyPreviewState(conversation: [.user(firstPrompt), .assistant(completed)], isSending: false)
    let firstRows = try TranscriptRowProjectionCache.project(
      fixture.controller.transcriptProjectionInput, options: options)
    let firstActive = TranscriptActiveRowProjection.rows(for: .assistant(completed))
    fixture.configure(rows: firstRows, activeRows: firstActive, rowsRevision: 1, activeRevision: 1)
    try fixture.present()
    fixture.window.orderFront(nil)
    defer { fixture.window.orderOut(nil) }

    let followUp = UserMessage(text: "Follow-up message")
    var assistant = AssistantMessage(turn: AssistantTurn(isGenerating: true))
    TranscriptReducer.apply(.agentThoughtChunk(.text("reasoning")), to: &assistant.turn)
    fixture.model.applyPreviewState(
      conversation: [.user(firstPrompt), .assistant(completed), .user(followUp), .assistant(assistant)], isSending: true
    )
    let nextRows = try TranscriptRowProjectionCache.project(
      fixture.controller.transcriptProjectionInput, options: options)
    let request = UserSendAnimationRequest(token: 7, messageID: followUp.id)
    fixture.configure(rows: nextRows, activeRows: firstActive, rowsRevision: 2, activeRevision: 1, sendRequest: request)
    try fixture.present()
    let userHost = try #require(fixture.view.mountedHosts[TranscriptVirtualRow.ID.message(followUp.id).layoutKey])
    try #require(userHost.layer?.animation(forKey: TranscriptSendAnimationKeys.lift) != nil)
    fixture.configure(
      rows: nextRows, activeRows: TranscriptActiveRowProjection.rows(for: .assistant(assistant)),
      rowsRevision: 2, activeRevision: 2, sendRequest: request)
    try fixture.present()

    // Await Core Animation's actual completion callback; no timed run-loop
    // drains and no extra model event or root-view refresh follows it.
    var completions = fixture.sendCompletions.makeAsyncIterator()
    #expect(await completions.next() == request.token)
    try fixture.expectActivity(for: assistant.id)
    #expect(assistant.turn.entries.isEmpty)
  }

  @Test("A follow-up publishes activity after an older projection misses its frame", .timeLimit(.minutes(1)))
  func followUpOvertakesStagedProjection() async throws {
    let fixture = ActivityFixture()
    defer { fixture.tearDown() }
    let options = TranscriptProjectionOptions(includesConnectingRow: false, bottomSpacerHeight: 100)
    let firstPrompt = UserMessage(text: "First message")
    var completed = AssistantMessage(
      turn: AssistantTurn(entries: [.text(id: "answer", markdown: "First answer")], isGenerating: true))
    fixture.model.applyPreviewState(conversation: [.user(firstPrompt), .assistant(completed)], isSending: true)
    let firstRows = try TranscriptRowProjectionCache.project(
      fixture.controller.transcriptProjectionInput, options: options)
    let projection = ProjectionFixture(controller: fixture.controller, rows: firstRows)
    defer { projection.tearDown() }
    var frames = projection.frames.makeAsyncIterator()
    var publications = projection.publications.makeAsyncIterator()

    try #require(await frames.next() != nil)
    projection.fireFrame()
    let firstActive = try #require(await publications.next())
    fixture.configure(rows: firstRows, activeRows: firstActive, rowsRevision: 1, activeRevision: 1)
    try fixture.present()

    completed.turn.isGenerating = false
    fixture.model.activeItem = .assistant(completed)
    fixture.model.isSending = false
    projection.layout()
    // The worker has finished the completed response, but its rows have
    // not published yet. Hold that display frame while the next turn starts.
    try #require(await frames.next() != nil)

    let followUp = UserMessage(text: "Follow-up message")
    var assistant = AssistantMessage(turn: AssistantTurn(isGenerating: true))
    TranscriptReducer.apply(.agentThoughtChunk(.text("reasoning")), to: &assistant.turn)
    fixture.model.applyPreviewState(
      conversation: [.user(firstPrompt), .assistant(completed), .user(followUp), .assistant(assistant)], isSending: true
    )
    projection.inputs.rows = try TranscriptRowProjectionCache.project(
      fixture.controller.transcriptProjectionInput, options: options)
    projection.layout()
    projection.fireFrame()

    try #require(await frames.next() != nil)
    projection.fireFrame()
    let nextActive = try #require(await publications.next())
    #expect(nextActive.contains { $0.id.messageID == assistant.id })
    fixture.configure(rows: projection.inputs.rows, activeRows: nextActive, rowsRevision: 2, activeRevision: 2)
    try fixture.present()
    try fixture.expectActivity(for: assistant.id)
    #expect(assistant.turn.entries.isEmpty)
  }

  @Test("A previous response's animation stops suppressing a quiet follow-up", arguments: [false, true])
  func previousAnimationRetires(previousResponseLeavesViewport: Bool) throws {
    let fixture = ActivityFixture(reportsPreviousAnimation: true)
    defer { fixture.tearDown() }
    let options = TranscriptProjectionOptions(includesConnectingRow: false, bottomSpacerHeight: 100)
    let firstPrompt = UserMessage(text: "First message")
    var completed = AssistantMessage(
      turn: AssistantTurn(
        entries: [.text(id: "answer", markdown: "First answer")], isGenerating: true, isThinking: true))
    fixture.model.applyPreviewState(conversation: [.user(firstPrompt), .assistant(completed)], isSending: true)
    let firstRows = try TranscriptRowProjectionCache.project(
      fixture.controller.transcriptProjectionInput, options: options)
    fixture.configure(
      rows: firstRows, activeRows: TranscriptActiveRowProjection.rows(for: .assistant(completed)),
      rowsRevision: 1, activeRevision: 1)
    try fixture.present()
    try #require(fixture.visibility.hasActiveEntranceAnimation)
    try fixture.expectActivity(for: completed.id, visible: false)
    let firstMarkdown = try #require(
      fixture.view.rows.first { row in
        if case .markdownChunk = row.content { true } else { false }
      })

    completed.turn.isGenerating = false
    completed.turn.isThinking = false
    let followUp = UserMessage(
      text: previousResponseLeavesViewport ? String(repeating: "Follow-up\n", count: 40) : "Follow-up")
    var assistant = AssistantMessage(turn: AssistantTurn(isGenerating: true))
    TranscriptReducer.apply(.agentThoughtChunk(.text("reasoning")), to: &assistant.turn)
    fixture.model.applyPreviewState(
      conversation: [.user(firstPrompt), .assistant(completed), .user(followUp), .assistant(assistant)], isSending: true
    )
    let nextRows = try TranscriptRowProjectionCache.project(
      fixture.controller.transcriptProjectionInput, options: options)
    fixture.configure(
      rows: nextRows, activeRows: TranscriptActiveRowProjection.rows(for: .assistant(assistant)),
      rowsRevision: 2, activeRevision: 2)
    try fixture.present()
    if previousResponseLeavesViewport {
      #expect(
        fixture.view.mountedHosts[firstMarkdown.layoutKey]?.frame.intersects(fixture.view.contentView.bounds) != true)
    }
    #expect(!fixture.visibility.hasActiveEntranceAnimation)
    try fixture.expectActivity(for: assistant.id)
    #expect(assistant.turn.entries.isEmpty)
  }

  @Test(
    "A quiet follow-up renders activity regardless of projection arrival order",
    arguments: [false, true],
    [
      (thinkingArrivesBeforeProjection: false, historyTurns: 0),
      (thinkingArrivesBeforeProjection: true, historyTurns: 0),
      (thinkingArrivesBeforeProjection: true, historyTurns: 500),
    ]
  )
  func quietFollowUp(
    activeProjectionArrivesFirst: Bool, scenario: (thinkingArrivesBeforeProjection: Bool, historyTurns: Int)
  ) async throws {
    let fixture = ActivityFixture()
    defer { fixture.tearDown() }
    let cache = TranscriptRowProjectionCache()
    let options = TranscriptProjectionOptions(includesConnectingRow: false, bottomSpacerHeight: 100)

    let firstPrompt = UserMessage(text: "First message")
    let completed = AssistantMessage(turn: AssistantTurn(entries: [.text(id: "answer", markdown: "First answer")]))
    var history: [ConversationItem] = (0..<scenario.historyTurns).flatMap { index in
      [
        .user(UserMessage(text: "Earlier message \(index)")),
        .assistant(
          AssistantMessage(turn: AssistantTurn(entries: [.text(id: "answer", markdown: "Earlier answer \(index)")]))),
      ]
    }
    history += [.user(firstPrompt), .assistant(completed)]
    fixture.model.applyPreviewState(conversation: history, isSending: false)
    let firstRows = try await cache.rows(
      for: fixture.controller.transcriptProjectionKey, input: fixture.controller.transcriptProjectionInput,
      options: options)
    let firstActive = TranscriptActiveRowProjection.rows(for: .assistant(completed))
    fixture.configure(rows: firstRows, activeRows: firstActive, rowsRevision: 1, activeRevision: 1)
    try fixture.present()

    let followUp = UserMessage(text: "Follow-up message")
    var assistant = AssistantMessage(turn: AssistantTurn(isGenerating: true))
    if scenario.thinkingArrivesBeforeProjection {
      TranscriptReducer.apply(.agentThoughtChunk(.text("reasoning")), to: &assistant.turn)
    }
    history.append(.user(followUp))
    fixture.model.applyPreviewState(conversation: history + [.assistant(assistant)], isSending: true)
    let nextRows = try await cache.rows(
      for: fixture.controller.transcriptProjectionKey, input: fixture.controller.transcriptProjectionInput,
      options: options)
    let nextActive = TranscriptActiveRowProjection.rows(for: .assistant(assistant))

    if activeProjectionArrivesFirst {
      fixture.configure(rows: firstRows, activeRows: nextActive, rowsRevision: 1, activeRevision: 2)
    } else {
      fixture.configure(rows: nextRows, activeRows: firstActive, rowsRevision: 2, activeRevision: 1)
    }
    try fixture.present()
    fixture.configure(rows: nextRows, activeRows: nextActive, rowsRevision: 2, activeRevision: 2)
    try fixture.present()
    try fixture.expectActivity(for: assistant.id)

    if !scenario.thinkingArrivesBeforeProjection {
      TranscriptReducer.apply(.agentThoughtChunk(.text("reasoning")), to: &assistant.turn)
      fixture.model.activeItem = .assistant(assistant)
      fixture.configure(
        rows: nextRows, activeRows: TranscriptActiveRowProjection.rows(for: .assistant(assistant)),
        rowsRevision: 2, activeRevision: 3)
      try fixture.present()
      try fixture.expectActivity(for: assistant.id)
    }

    // The server may adopt the assistant's canonical id before the outer
    // projection catches up. No text/tool event follows this handoff.
    let canonical = AssistantMessage(id: UUID(), turn: assistant.turn)
    fixture.model.adoptActiveAssistantItemIdentity(canonical.id)
    fixture.configure(
      rows: nextRows, activeRows: TranscriptActiveRowProjection.rows(for: .assistant(canonical)),
      rowsRevision: 2, activeRevision: 4)
    try fixture.present()
    let canonicalRows = try await cache.rows(
      for: fixture.controller.transcriptProjectionKey, input: fixture.controller.transcriptProjectionInput,
      options: options)
    fixture.configure(
      rows: canonicalRows, activeRows: TranscriptActiveRowProjection.rows(for: .assistant(canonical)),
      rowsRevision: 3, activeRevision: 4)
    try fixture.present()
    try fixture.expectActivity(for: canonical.id)
    #expect(canonical.turn.entries.isEmpty)
  }
}

@Observable
@MainActor
private final class ProjectionInputs {
  var rows: [TranscriptVirtualRow]

  init(rows: [TranscriptVirtualRow]) {
    self.rows = rows
  }
}

@MainActor
private final class ProjectionFixture {
  let inputs: ProjectionInputs
  let frames: AsyncStream<Void>
  let publications: AsyncStream<[TranscriptVirtualRow]>
  private let frameContinuation: AsyncStream<Void>.Continuation
  private let publicationContinuation: AsyncStream<[TranscriptVirtualRow]>.Continuation
  private let controller: SessionController
  private let token: TranscriptFrameDriverToken
  private let host: NSHostingView<AnyView>
  private let window: NSWindow

  init(controller: SessionController, rows: [TranscriptVirtualRow]) {
    self.controller = controller
    inputs = ProjectionInputs(rows: rows)
    (frames, frameContinuation) = AsyncStream.makeStream()
    (publications, publicationContinuation) = AsyncStream.makeStream()
    let frameContinuation = self.frameContinuation
    token = controller.presentationClock.registerDriver(maximumFramesPerSecond: 120) {
      frameContinuation.yield(())
    }
    let inputs = self.inputs
    let publicationContinuation = self.publicationContinuation
    host = NSHostingView(
      rootView: AnyView(
        ProjectionHost(controller: controller, inputs: inputs) { rows in
          publicationContinuation.yield(rows)
        }))
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    layout()
  }

  func layout() {
    host.layoutSubtreeIfNeeded()
  }

  func fireFrame() {
    controller.presentationClock.didFire(token)
    layout()
  }

  func tearDown() {
    window.contentView = nil
    controller.presentationClock.unregisterDriver(token)
    frameContinuation.finish()
    publicationContinuation.finish()
  }
}

private struct ProjectionHost: View {
  let controller: SessionController
  let inputs: ProjectionInputs
  let onPublication: ([TranscriptVirtualRow]) -> Void

  var body: some View {
    ActiveTranscriptProjectionScope(controller: controller, projectedRows: inputs.rows) { rows, revision, _, _, _ in
      Color.clear.onChange(of: revision) { _, _ in onPublication(rows) }
    }
  }
}

@MainActor
private final class ActivityFixture {
  let controller = SessionController(
    project: .fromFolder(URL(fileURLWithPath: "/tmp/follow-up-activity-tests")),
    configCache: ConfigOptionCache(store: InMemoryStore()))
  let model: SessionModel
  let view: VirtualizedTranscriptScrollView
  let window: NSWindow
  let visibility = StreamingTextAnimationVisibility()
  let registry = StreamingTextAnimationRegistry()
  let sendCompletions: AsyncStream<UInt64>
  private let sendCompletionContinuation: AsyncStream<UInt64>.Continuation

  init(reportsPreviousAnimation: Bool = false) {
    (sendCompletions, sendCompletionContinuation) = AsyncStream.makeStream()
    _ = NSApplication.shared
    let sessionID = UUID()
    model = SessionModel(
      serverTransport: ServerSessionTransport(client: CodevisorServerClient(), sessionId: sessionID),
      sessionId: sessionID.uuidString)
    controller.model = model
    view = VirtualizedTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.sessionController = controller
    // Deliver the native surface's requested frames explicitly. This link
    // is never registered with the run loop, so scheduler timing cannot
    // decide which projection or measurement arrives first.
    view.presentationDisplayLink = view.displayLink(
      target: view, selector: #selector(view.presentationDisplayLinkDidFire(_:)))
    self.reportsPreviousAnimation = reportsPreviousAnimation
  }

  private let reportsPreviousAnimation: Bool

  func configure(
    rows: [TranscriptVirtualRow], activeRows: [TranscriptVirtualRow], rowsRevision: UInt64, activeRevision: UInt64,
    sendRequest: UserSendAnimationRequest? = nil
  ) {
    let settledVisibility = TranscriptWorkedRowsVisibility.present(
      rows, disclosure: controller.disclosure, activeItem: controller.activeItem,
      runningSubagentRunToolCallIDs: []
    ).visibilityRevision
    let activeVisibility = TranscriptWorkedRowsVisibility.present(
      activeRows, disclosure: controller.disclosure, activeItem: controller.activeItem,
      runningSubagentRunToolCallIDs: []
    ).visibilityRevision
    view.configure(
      TranscriptSurfaceInput(
        sessionController: controller, rows: rows, activeRows: activeRows,
        activeRowsVersion: .init(sourceRevision: activeRevision, visibilityRevision: activeVisibility),
        rowsVersion: .init(sourceRevision: rowsRevision, visibilityRevision: settledVisibility),
        projectionRevision: rowsRevision, initialState: nil, followsLatest: true,
        hasOlderHistory: false, showsOlderHistoryLoadingIndicator: false,
        isLoadingInitialHistory: false, isPreparingInitialProjection: false,
        isActiveProjectionPending: false, layoutFingerprint: 0,
        scrollCommand: .init(), sendAnimationRequest: sendRequest,
        textAnimationRegistry: registry, reduceMotion: sendRequest == nil),
      callbacks: TranscriptSurfaceCallbacks(
        claimSendAnimation: { _ in true },
        rowContent: { [controller, visibility, registry, reportsPreviousAnimation] row in
          AnyView(
            TranscriptRowContentView(row: row, controller: controller, leaves: Self.leaves)
              // Control the renderer's animation preference at the reporter
              // boundary; glyph-fade timing is not part of this lifecycle test.
              .preference(
                key: StreamingMarkdownEntranceAnimationPreferenceKey.self,
                value: reportsPreviousAnimation && Self.isReceivingMarkdown(row)
              )
              .reportsStreamingTextAnimationActivity()
              .environment(\.streamingTextAnimationVisibility, visibility)
              .environment(\.streamingTextAnimationRegistry, registry)
              .environment(\.colorScheme, .light))
        },
        onViewportChange: { _ in }, onBottomStateChange: { _ in },
        onFollowStateChange: { _ in }, onNearTop: { false },
        onSendAnimationCompleted: { [sendCompletionContinuation] in sendCompletionContinuation.yield($0.token) }))
  }

  func present() throws {
    view.layoutSubtreeIfNeeded()
    view.updateMountedRows()
    while view.displayFrameRequested || !view.pendingMeasuredHeights.isEmpty {
      view.surfaceController.presentFrame(at: 0, adapter: view)
      view.layoutSubtreeIfNeeded()
    }
    try #require(view.initialPresentationGate.isReady)
  }

  func expectActivity(for assistantID: UUID, visible: Bool = true) throws {
    let row = try #require(view.rows.first { $0.id == .activeChrome(assistantID, .activity) })
    let host = try #require(view.mountedHosts[row.layoutKey])
    #expect(host.frame.height > 10)
    #expect(host.frame.intersects(view.contentView.bounds))
    #expect(view.transcriptDocumentView.alphaValue == 1)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let visiblePixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
      count
        + (0..<bitmap.pixelsWide).filter { x in
          (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
        }.count
    }
    if visible {
      #expect(visiblePixels > 20, "The activity row must contain visible glyphs without a later text or tool event")
    } else {
      #expect(visiblePixels == 0, "Activity is suppressed while the previous response's text is entering")
    }
  }

  private static func isReceivingMarkdown(_ row: TranscriptVirtualRow) -> Bool {
    guard case let .markdownChunk(chunk) = row.content else { return false }
    return chunk.lifecycle == .receiving
  }

  func tearDown() {
    view.prepareForDismantle()
    window.contentView = nil
    sendCompletionContinuation.finish()
  }

  private static func conversation(_ item: ConversationItem) -> AnyView {
    switch item {
    case let .user(message): AnyView(Text(message.text))
    case let .assistant(message): AnyView(ActivityLeaf(turn: message.turn))
    }
  }

  private static var leaves: TranscriptRowLeaves {
    TranscriptRowLeaves(
      conversationItem: { item, _, _, _ in conversation(item) },
      activeConversationItem: { item, _, _, _, _ in conversation(item) },
      assistantTurn: { message, _, _, _ in AnyView(ActivityLeaf(turn: message.turn)) },
      userMessage: { AnyView(Text($0.text)) },
      workedItem: { _, _, _, _, _, _ in AnyView(EmptyView()) },
      attachmentThumbnail: { _ in AnyView(EmptyView()) },
      setup: { _ in AnyView(EmptyView()) },
      errorRow: { text, _ in AnyView(Text(text)) })
  }
}

private struct ActivityLeaf: View {
  let turn: AssistantTurn

  var body: some View {
    VStack(alignment: .leading) {
      if turn.reservesActivitySlot {
        AssistantTurnActivitySlot(
          AssistantTurnActivity.resolve(
            turn: turn, isWaitingOnUser: false, sessionActivity: nil,
            backgroundTask: nil, goalActivity: nil))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
