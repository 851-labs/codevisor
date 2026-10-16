import Foundation
import Testing
@testable import ACPKit

@Suite("Protocol Codable")
struct ProtocolCodableTests {
  private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    #expect(decoded == value)
  }

  private func assertWire<T: Codable & Equatable>(_ value: T, json: String) throws {
    let literal = Data(json.utf8)
    let encoded = try JSONEncoder().encode(value)
    let actual = try #require(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
    let expected = try #require(try JSONSerialization.jsonObject(with: literal) as? NSDictionary)
    #expect(actual == expected)
    #expect(try JSONDecoder().decode(T.self, from: literal) == value)
  }

  @Test("ContentBlock variants round-trip")
  func contentBlocks() throws {
    try assertWire(
      ContentBlock.text("hi", annotations: Annotations(audience: [.user], priority: 0.5)),
      json: #"{"type":"text","text":"hi","annotations":{"audience":["user"],"priority":0.5}}"#)
    try assertWire(
      ContentBlock.image(data: "AAAA", mimeType: "image/png", uri: "file://x"),
      json: #"{"type":"image","data":"AAAA","mimeType":"image/png","uri":"file://x"}"#)
    try assertWire(
      ContentBlock.audio(data: "BBBB", mimeType: "audio/wav"),
      json: #"{"type":"audio","data":"BBBB","mimeType":"audio/wav"}"#)
    try assertWire(
      ContentBlock.resourceLink(
        ResourceLink(name: "n", uri: "u", description: "d", mimeType: "text/plain", title: "t", size: 10)),
      json:
        #"{"type":"resource_link","name":"n","uri":"u","description":"d","mimeType":"text/plain","title":"t","size":10}"#
    )
    try assertWire(
      ContentBlock.resource(.text(uri: "u", text: "hello", mimeType: "text/plain")),
      json: #"{"type":"resource","resource":{"uri":"u","text":"hello","mimeType":"text/plain"}}"#)
    try assertWire(
      ContentBlock.resource(.blob(uri: "u", blob: "QkJCQg==", mimeType: nil)),
      json: #"{"type":"resource","resource":{"uri":"u","blob":"QkJCQg=="}}"#)
  }

  @Test("ContentBlock decodes by type discriminator")
  func contentBlockDiscriminator() throws {
    let data = Data(#"{"type":"text","text":"yo"}"#.utf8)
    let block = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(block.textValue == "yo")
  }

  @Test("Message chunk phase decodes leniently")
  func messageChunkPhase() throws {
    let tagged = Data(
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"},"messageId":"m1","phase":"final"}"#
        .utf8
    )
    let update = try JSONDecoder().decode(SessionUpdate.self, from: tagged)
    guard case let .agentMessageChunk(_, _, _, phase) = update else {
      Issue.record("Expected agentMessageChunk")
      return
    }
    #expect(phase == .final)

    let unknown = Data(
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"},"phase":"interlude"}"#
        .utf8
    )
    let lenient = try JSONDecoder().decode(SessionUpdate.self, from: unknown)
    guard case let .agentMessageChunk(_, _, _, lenientPhase) = lenient else {
      Issue.record("Expected agentMessageChunk")
      return
    }
    #expect(lenientPhase == nil)
  }

  @Test("Skills update decodes the server's inline snapshot, tolerating unknown sources")
  func availableSkillsUpdate() throws {
    let data = Data(
      #"""
      {"sessionUpdate":"available_skills_update","invocationPrefix":"$","skills":[
        {"name":"code-review","description":"Review the diff","invocation":"$code-review","source":"project"},
        {"name":"deploy","invocation":"$deploy","source":"marketplace"}
      ]}
      """#.utf8
    )
    let update = try JSONDecoder().decode(SessionUpdate.self, from: data)
    #expect(
      update
        == .availableSkillsUpdate(
          SessionSkills(
            skills: [
              SessionSkill(
                name: "code-review",
                description: "Review the diff",
                invocation: "$code-review",
                source: .project
              ),
              SessionSkill(name: "deploy", invocation: "$deploy", source: nil),
            ],
            invocationPrefix: "$"
          )))
  }

  @Test("Unknown content block type throws")
  func unknownContentBlock() {
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(ContentBlock.self, from: Data(#"{"type":"video"}"#.utf8))
    }
  }

  @Test("SessionUpdate variants round-trip")
  func sessionUpdates() throws {
    try roundTrip(SessionUpdate.agentMessageChunk(.text("a")))
    try roundTrip(SessionUpdate.agentMessageChunk(.text("a"), messageId: "msg-1"))
    try roundTrip(SessionUpdate.agentMessageChunk(.text("a"), messageId: "msg-1", parentToolCallId: "task-1"))
    try roundTrip(
      SessionUpdate.agentMessageChunk(.text("a"), messageId: "msg-1", parentToolCallId: nil, phase: .final))
    try roundTrip(
      SessionUpdate.agentMessageChunk(.text(""), messageId: "msg-1", parentToolCallId: nil, phase: .commentary))
    try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking")))
    try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking"), messageId: "thought-1"))
    try roundTrip(SessionUpdate.agentThoughtChunk(.text("thinking"), messageId: nil, parentToolCallId: "task-1"))
    try roundTrip(SessionUpdate.userMessageChunk(.text("u")))
    try roundTrip(SessionUpdate.userMessageChunk(.text("u"), messageId: "user-1"))
    try roundTrip(SessionUpdate.toolCall(ToolCall(toolCallId: "t1", title: "Read", kind: .read, status: .pending)))
    try roundTrip(SessionUpdate.toolCallUpdate(ToolCallUpdate(toolCallId: "t1", status: .completed)))
    try roundTrip(
      SessionUpdate.plan(Plan(entries: [PlanEntry(content: "step", priority: .high, status: .pending)])))
    try roundTrip(SessionUpdate.availableCommandsUpdate([AvailableCommand(name: "test", description: "run")]))
    try roundTrip(
      SessionUpdate.availableSkillsUpdate(
        SessionSkills(skills: [SessionSkill(name: "review", invocation: "/review", source: .builtin)])))
    try roundTrip(SessionUpdate.currentModeUpdate(currentModeId: "fast"))
    let boundedGoal = SessionUpdate.goalUpdate(
      SessionGoal(
        objective: "ship goal mode",
        status: .active,
        activity: .verifying,
        tokenBudget: 50_000,
        tokensUsed: 1_200,
        timeUsedSeconds: 42.125,
        createdAt: "2026-07-05T00:00:00.000Z",
        updatedAt: "2026-07-05T00:01:00.000Z"
      ))
    try roundTrip(boundedGoal)
    try assertWire(
      boundedGoal,
      json:
        #"{"sessionUpdate":"goal_update","goal":{"objective":"ship goal mode","status":"active","activity":"verifying","tokenBudget":50000,"tokensUsed":1200,"timeUsedSeconds":42.125,"createdAt":"2026-07-05T00:00:00.000Z","updatedAt":"2026-07-05T00:01:00.000Z"}}"#
    )
    let unboundedGoal = SessionUpdate.goalUpdate(SessionGoal(objective: "unbounded", status: .paused))
    try roundTrip(unboundedGoal)
    try assertWire(
      unboundedGoal,
      json:
        #"{"sessionUpdate":"goal_update","goal":{"objective":"unbounded","status":"paused","tokensUsed":0,"timeUsedSeconds":0,"createdAt":"","updatedAt":""}}"#
    )
    try roundTrip(SessionUpdate.goalCleared)
    try assertWire(SessionUpdate.goalCleared, json: #"{"sessionUpdate":"goal_cleared"}"#)
    try roundTrip(
      SessionUpdate.question(
        QuestionRequest(
          questionId: "q-1",
          message: "GitHub needs a few details.",
          questions: [
            QuestionSpec(
              id: "approach",
              header: "Approach",
              question: "Which approach?",
              options: [
                QuestionOption(label: "MVP first (Recommended)", description: "Fast."),
                QuestionOption(label: "Full design"),
              ],
              multiSelect: false,
              allowsOther: true,
              backOptionLabel: "Back",
              presentation: .browserExtensionSetup
            )
          ],
          autoResolutionMs: 60_000
        )))
    try roundTrip(
      SessionUpdate.questionResolved(
        QuestionResolution(
          questionId: "q-1",
          outcome: .answered,
          questions: [QuestionSpec(id: "approach", question: "Which approach?")],
          answers: ["approach": QuestionAnswerEntry(answers: ["MVP first"], note: "keep it lean")]
        )))
    try roundTrip(
      SessionUpdate.questionResolved(
        QuestionResolution(
          questionId: "q-2",
          outcome: .cancelled,
          questions: []
        )))
    try roundTrip(
      SessionUpdate.question(
        QuestionRequest(
          questionId: "browser-choice",
          questions: [
            QuestionSpec(
              id: "browser_preference",
              question: "Which browser should I use?",
              options: [QuestionOption(label: "Use Codevisor Browser")],
              allowsOther: false,
              presentation: .browserChoice
            )
          ]
        )))
  }

  @Test("Context compaction preserves server wire tags, statuses and omitted IDs")
  func contextCompactionWire() throws {
    let cases: [(SessionUpdate, String)] = [
      (
        .contextCompaction(id: "compact-1", status: .started),
        #"{"sessionUpdate":"context_compaction","compactionId":"compact-1","status":"started"}"#
      ),
      (
        .contextCompaction(id: "compact-1", status: .completed),
        #"{"sessionUpdate":"context_compaction","compactionId":"compact-1","status":"completed"}"#
      ),
      (
        .contextCompaction(id: nil, status: .failed),
        #"{"sessionUpdate":"context_compaction","status":"failed"}"#
      ),
    ]
    for (update, json) in cases {
      try roundTrip(update)
      try assertWire(update, json: json)
    }
  }

  @Test("Plan documents preserve server wire tag and markdown bytes")
  func planDocumentWire() throws {
    let update = SessionUpdate.planDocument(markdown: "# The Plan\n\n1. Do it")
    try roundTrip(update)
    try assertWire(
      update, json: ##"{"sessionUpdate":"plan_document","markdown":"# The Plan\n\n1. Do it"}"##)
  }

  @Test("Goal update decodes a null token budget and rejects unknown statuses")
  func goalDecoding() throws {
    let data = Data(
      """
      {"sessionUpdate":"goal_update","goal":{"objective":"o","status":"budgetLimited",\
      "tokenBudget":null,"tokensUsed":5,"timeUsedSeconds":9.25,"createdAt":"c","updatedAt":"u"}}
      """.utf8)
    let update = try JSONDecoder().decode(SessionUpdate.self, from: data)
    guard case .goalUpdate(let goal) = update else { Issue.record("expected goal_update"); return }
    #expect(goal.tokenBudget == nil)
    #expect(goal.status == .budgetLimited)
    #expect(goal.timeUsedSeconds == 9.25)

    let unknownStatus = Data(
      """
      {"sessionUpdate":"goal_update","goal":{"objective":"o","status":"someday",\
      "tokensUsed":0,"timeUsedSeconds":0,"createdAt":"c","updatedAt":"u"}}
      """.utf8)
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(SessionUpdate.self, from: unknownStatus)
    }
  }

  @Test("tool_call update carries inline fields")
  func toolCallInline() throws {
    let data = Data(
      #"{"sessionUpdate":"tool_call","toolCallId":"x","title":"Search","kind":"search","status":"in_progress"}"#
        .utf8)
    let update = try JSONDecoder().decode(SessionUpdate.self, from: data)
    guard case .toolCall(let call) = update else { Issue.record("expected tool_call"); return }
    #expect(call.toolCallId == "x")
    #expect(call.kind == .search)
    #expect(call.status == .inProgress)
  }

  @Test("Unknown session update throws")
  func unknownUpdate() {
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(SessionUpdate.self, from: Data(#"{"sessionUpdate":"???"}"#.utf8))
    }
  }

  @Test("ToolCallContent variants round-trip")
  func toolCallContent() throws {
    try assertWire(
      ToolCallContent.content(.text("out")),
      json: #"{"type":"content","content":{"type":"text","text":"out"}}"#)
    try assertWire(
      ToolCallContent.diff(path: "/a.txt", oldText: "x", newText: "y"),
      json: #"{"type":"diff","path":"/a.txt","oldText":"x","newText":"y"}"#)
    try assertWire(
      ToolCallContent.terminal(terminalId: "term-1"),
      json: #"{"type":"terminal","terminalId":"term-1"}"#)
  }

  @Test("Unknown tool call content throws")
  func unknownToolCallContent() {
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(ToolCallContent.self, from: Data(#"{"type":"zzz"}"#.utf8))
    }
  }

  @Test("ToolKind decodes unknown values as other")
  func toolKindLenient() throws {
    let kind = try JSONDecoder().decode(ToolKind.self, from: Data("\"telepathy\"".utf8))
    #expect(kind == .other)
    let known = try JSONDecoder().decode(ToolKind.self, from: Data("\"execute\"".utf8))
    #expect(known == .execute)
  }
}
