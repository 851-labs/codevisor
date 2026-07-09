import { createFileRoute } from "@tanstack/react-router"
import type { AttachmentRef, ConversationItem, PromptQueueItem, SessionGoal } from "@herdman/api"
import { useMemo, useState } from "react"

import type { BackgroundTaskInfo, PlanEntryInfo, ToolCallInfo } from "../../lib/session-events"
import type { TurnMeta } from "../../lib/queries"
import { AssistantTurn } from "../../features/session/AssistantTurn"
import { PlanView, TodoPanelView } from "../../features/session/PlanView"
import { PromptQueue } from "../../features/session/PromptQueue"
import { GoalBanner, WaitingBackgroundTaskIndicator } from "../../features/session/SessionScreen"
import { MessageCopyButton } from "../../features/session/MessageCopyButton"
import { ToolCallRow, ToolGroup } from "../../features/session/ToolGroup"
import { Transcript, UserMessage } from "../../features/session/Transcript"

export const Route = createFileRoute("/_shell/verify/chat-parity")({
  component: ChatParityFixtureRoute
})

const sampleTodos: PlanEntryInfo[] = [
  {
    content: "Read the existing macOS session views",
    priority: "high",
    status: "completed"
  },
  {
    content: "Implement the Tauri plan and todo rendering",
    priority: "medium",
    status: "in_progress"
  },
  {
    content: "Capture verification screenshots",
    priority: "low",
    status: "pending"
  }
]

const samplePlan = `# Add goal banner

1. Extend the wire schema with \`SessionGoal\`
2. Map codex \`thread/goal/*\` in the provider
3. Render the banner above the composer

**Verification**: run the dev app and set a goal.`

const richMarkdownSample = `A paragraph with **bold**, *italic*, and \`inline code\`.

> Keep quote blocks aligned with the macOS transcript.

| Name | Role |
| :--- | ---: |
| Web | Renderer |

\`\`\`swift
let greeting = "Hello"
print(greeting)
\`\`\`

Done.`

const sampleQueue: PromptQueueItem[] = [
  {
    id: "queued-1",
    sessionId: "verify-session",
    text: "After this finishes, summarize the implementation tradeoffs and call out any remaining parity gaps.",
    createdAt: "2026-07-08T12:00:00.000Z",
    updatedAt: "2026-07-08T12:00:00.000Z"
  },
  {
    id: "queued-2",
    sessionId: "verify-session",
    text: "Then run the chat verifier again with an expanded tool call and a proposed plan so we can compare against the macOS layout.",
    createdAt: "2026-07-08T12:01:00.000Z",
    updatedAt: "2026-07-08T12:01:00.000Z"
  }
]

const sampleGoal: SessionGoal = {
  objective: "Match the macOS chat surface in Tauri",
  status: "active",
  tokenBudget: null,
  tokensUsed: 54_000,
  timeUsedSeconds: 90 * 60,
  createdAt: "2026-07-08T12:00:00.000Z",
  updatedAt: "2026-07-08T13:30:00.000Z"
}

const sampleUserAttachments: AttachmentRef[] = [
  {
    fileId: "fixture-file",
    name: "notes.txt",
    mimeType: "text/plain",
    sizeBytes: 2048,
    kind: "file"
  }
]

const longUserMessage =
  "Please compare the macOS transcript row behavior against the Tauri implementation, including this long path-like token that should wrap inside the bubble: /Users/alexandru/repos/851-labs/herdman/apps/web/src/features/session/Transcript.tsx?with=a-very-long-query-string-for-wrapping-verification"

const transcriptWaitingConversation: ConversationItem[] = [
  {
    id: "waiting-user",
    role: "user",
    text: "Kick off the long-running verification task.",
    createdAt: "2026-07-08T12:02:00.000Z",
    isGenerating: false
  }
]

const waitingTasks: BackgroundTaskInfo[] = [
  {
    id: "bg-1",
    description: "Inspect transcript rendering",
    status: "running",
    taskType: "subagent"
  },
  {
    id: "bg-2",
    description: "Run fixture capture",
    status: "running",
    taskType: "shell"
  }
]

const sampleToolCalls: ToolCallInfo[] = [
  {
    toolCallId: "verify-diff",
    title: "Edited Composer.tsx",
    kind: "edit",
    status: "completed",
    content: [
      {
        type: "diff",
        path: "apps/web/src/features/composer/Composer.tsx",
        oldText:
          "        const maxHeight = 200\n        submitOrAcceptSlash()\n",
        newText:
          "        const maxHeight = 240\n        acceptSlashWithTab()\n        submitOrAcceptSlash()\n"
      }
    ]
  },
  {
    toolCallId: "verify-shell",
    title: 'Ran rg -n "ComposerCard"',
    kind: "execute",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "apps/macos/HerdMan/Features/Composer/ComposerView.swift:18:struct ComposerCard: View\napps/web/src/features/composer/Composer.tsx:34:export function Composer({"
        }
      }
    ]
  },
  {
    toolCallId: "verify-web",
    title: "Searched SwiftUI markdown rendering",
    kind: "web_search",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "resource_link",
          name: "StreamMarkdown",
          uri: "https://github.com/apple/swift-markdown",
          title: "Swift Markdown"
        }
      },
      {
        type: "content",
        content: {
          type: "resource_link",
          name: "",
          uri: "https://example.com/source-without-title"
        }
      }
    ]
  },
  {
    toolCallId: "verify-cancelled",
    title: "Cancelled long-running build",
    kind: "execute",
    status: "cancelled",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "$ bun run build\n^C"
        }
      }
    ]
  }
]

const firstIconToolCalls: ToolCallInfo[] = [
  {
    toolCallId: "verify-read-first",
    title: "Read README.md",
    kind: "read",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "# HerdMan"
        }
      }
    ]
  },
  {
    toolCallId: "verify-search-one",
    title: 'Ran rg -n "SessionView"',
    kind: "search",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "apps/macos/HerdMan/Features/Session/SessionView.swift:1:import SwiftUI"
        }
      }
    ]
  },
  {
    toolCallId: "verify-search-two",
    title: 'Ran rg -n "ToolGroupView"',
    kind: "search",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "apps/macos/HerdMan/Features/Session/ToolGroupView.swift:7:struct ToolGroupView: View"
        }
      }
    ]
  }
]

const shortShellToolCall: ToolCallInfo = {
  toolCallId: "verify-short-shell",
  title: "Ran pwd",
  kind: "execute",
  status: "completed",
  content: [
    {
      type: "content",
      content: {
        type: "text",
        text: "/Users/alexandru/repos/851-labs/herdman"
      }
    }
  ]
}

function ChatParityFixtureRoute() {
  const [expanded, setExpanded] = useState(true)
  const [queueExpanded, setQueueExpanded] = useState(true)
  const markdownOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("markdownOnly") === "1"
  const firstIconOnly =
    typeof window !== "undefined" &&
    (new URLSearchParams(window.location.search).get("firstIconOnly") === "1" ||
      new URLSearchParams(window.location.search).get("dominantOnly") === "1")
  const copyOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("copyOnly") === "1"
  const planOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("planOnly") === "1"
  const planListOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("planListOnly") === "1"
  const waitingOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("waitingOnly") === "1"
  const toolCardOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("toolCardOnly") === "1"
  const userOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("userOnly") === "1"
  const settledTimedTurn = useMemo(() => {
    const startedAt = "2026-07-08T12:04:00.000Z"
    const endedAt = "2026-07-08T12:04:36.000Z"
    const item: ConversationItem = {
      id: "assistant-settled-timed-turn",
      role: "assistant",
      text: "The stable worked duration should come from stream metadata.",
      createdAt: startedAt,
      isGenerating: false
    }
    const meta: TurnMeta = {
      startedAt,
      endedAt,
      thoughts: "",
      toolCalls: [sampleToolCalls[1]!],
      entries: [
        { type: "tool", call: sampleToolCalls[1]! },
        {
          type: "text",
          id: "timed-final",
          markdown: "The stable worked duration should come from stream metadata."
        }
      ],
      subagents: {},
      textPhases: { "timed-final": "final" },
      nextTextId: 1
    }
    return { item, meta }
  }, [])
  const plannedTurn = useMemo(() => {
    const startedAt = "2026-07-08T12:00:00.000Z"
    const endedAt = "2026-07-08T12:00:36.000Z"
    const item: ConversationItem = {
      id: "assistant-planned-turn",
      role: "assistant",
      text: "The plan is ready; implementation can continue below it.",
      createdAt: startedAt,
      isGenerating: false
    }
    const meta: TurnMeta = {
      startedAt,
      endedAt,
      thoughts: "",
      toolCalls: sampleToolCalls,
      entries: [
        {
          type: "text",
          id: "planning-note",
          markdown: "Checked the macOS plan and tool-call views before changing the Tauri surface."
        },
        { type: "tool", call: sampleToolCalls[1]! },
        { type: "tool", call: sampleToolCalls[0]! },
        {
          type: "text",
          id: "final-answer",
          markdown: "The plan is ready; implementation can continue below it."
        }
      ],
      subagents: {},
      textPhases: { "planning-note": "commentary", "final-answer": "final" },
      nextTextId: 1,
      planDocument: samplePlan,
      planBoundary: 2
    }
    return { item, meta }
  }, [])
  const assertedFinalTurn = useMemo(() => {
    const startedAt = new Date(Date.now() - 9_000).toISOString()
    const item: ConversationItem = {
      id: "assistant-asserted-final-turn",
      role: "assistant",
      text: "The final response has started streaming while the turn is still active.",
      createdAt: startedAt,
      isGenerating: true
    }
    const meta: TurnMeta = {
      startedAt,
      thoughts: "",
      toolCalls: [sampleToolCalls[1]!],
      entries: [
        { type: "tool", call: sampleToolCalls[1]! },
        {
          type: "text",
          id: "asserted-final",
          markdown: "The final response has started streaming while the turn is still active."
        }
      ],
      subagents: {},
      textPhases: { "asserted-final": "final" },
      nextTextId: 1,
      isThinking: true
    }
    return { item, meta }
  }, [])
  const richMarkdownTurn = useMemo(() => {
    const startedAt = "2026-07-08T12:03:00.000Z"
    const endedAt = "2026-07-08T12:03:08.000Z"
    const item: ConversationItem = {
      id: "assistant-rich-markdown-turn",
      role: "assistant",
      text: richMarkdownSample,
      createdAt: startedAt,
      isGenerating: false
    }
    const meta: TurnMeta = {
      startedAt,
      endedAt,
      thoughts: "",
      toolCalls: [],
      entries: [
        {
          type: "text",
          id: "rich-markdown",
          markdown: richMarkdownSample
        }
      ],
      subagents: {},
      textPhases: { "rich-markdown": "final" },
      nextTextId: 1
    }
    return { item, meta }
  }, [])

  if (markdownOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Rich markdown assistant turn">
            <AssistantTurn item={richMarkdownTurn.item} meta={richMarkdownTurn.meta} />
          </section>
        </div>
      </div>
    )
  }

  if (firstIconOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="First-call icon tool group">
            <ToolGroup calls={firstIconToolCalls} forceExpanded />
          </section>
        </div>
      </div>
    )
  }

  if (copyOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Visible transcript copy buttons" className="flex items-center gap-2">
            <MessageCopyButton text="Copy message fixture" label="Copy message" />
            <MessageCopyButton text="Copy response fixture" label="Copy response" />
          </section>
        </div>
      </div>
    )
  }

  if (planOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Planned assistant turn">
            <AssistantTurn item={plannedTurn.item} meta={plannedTurn.meta} />
          </section>
        </div>
      </div>
    )
  }

  if (planListOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Inline plan list">
            <PlanView entries={sampleTodos} />
          </section>
          <section aria-label="Expanded todos">
            <TodoPanelView
              entries={sampleTodos}
              isExpanded={expanded}
              onToggle={() => setExpanded((next) => !next)}
            />
          </section>
        </div>
      </div>
    )
  }

  if (waitingOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Waiting background task">
            <WaitingBackgroundTaskIndicator tasks={waitingTasks} />
          </section>
          <section aria-label="Transcript waiting placement" className="h-64 overflow-hidden">
            <Transcript
              conversation={transcriptWaitingConversation}
              composerOverlay={null}
              composerHeight={0}
              streamFingerprint="waiting-placement"
              waitingIndicator={<WaitingBackgroundTaskIndicator tasks={waitingTasks} />}
            />
          </section>
        </div>
      </div>
    )
  }

  if (toolCardOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Short shell tool row">
            <ToolCallRow call={shortShellToolCall} forceExpanded />
          </section>
        </div>
      </div>
    )
  }

  if (userOnly) {
    return (
      <div className="bg-background flex h-full flex-col overflow-auto">
        <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
          <section aria-label="Long selectable user message">
            <UserMessage text={longUserMessage} />
          </section>
          <section aria-label="User message with attachment">
            <UserMessage
              text="Can you make live attachment prompts render like macOS?"
              attachments={sampleUserAttachments}
            />
          </section>
        </div>
      </div>
    )
  }

  return (
    <div className="bg-background flex h-full flex-col overflow-auto">
      <div className="mx-auto flex w-full max-w-[880px] flex-col gap-4 px-6 py-8">
        <section aria-label="Expanded todos">
          <TodoPanelView
            entries={sampleTodos}
            isExpanded={expanded}
            onToggle={() => setExpanded((next) => !next)}
          />
        </section>
        <section aria-label="Collapsed todos">
          <TodoPanelView entries={sampleTodos} isExpanded={false} onToggle={() => undefined} />
        </section>
        <section aria-label="Goal banner">
          <GoalBanner
            goal={sampleGoal}
            isBusy={false}
            onPause={() => undefined}
            onResume={() => undefined}
            onEdit={() => undefined}
            onClear={() => undefined}
          />
        </section>
        <section aria-label="Prompt queue">
          <PromptQueue
            sessionId="verify-session"
            queue={sampleQueue}
            isExpanded={queueExpanded}
            onToggleExpanded={() => setQueueExpanded((next) => !next)}
          />
        </section>
        <section aria-label="User message with attachment near top">
          <UserMessage
            text="Can you make live attachment prompts render like macOS?"
            attachments={sampleUserAttachments}
          />
        </section>
        <section aria-label="Rich markdown assistant turn">
          <AssistantTurn item={richMarkdownTurn.item} meta={richMarkdownTurn.meta} />
        </section>
        <section aria-label="Settled worked duration">
          <AssistantTurn item={settledTimedTurn.item} meta={settledTimedTurn.meta} />
        </section>
        <section aria-label="Cancelled tool row status badge">
          <ToolCallRow call={sampleToolCalls[3]!} forceExpanded />
        </section>
        <section aria-label="Web search sources">
          <ToolCallRow call={sampleToolCalls[2]!} forceExpanded />
        </section>
        <section aria-label="Diff fallback tool row">
          <ToolCallRow call={sampleToolCalls[0]!} forceExpanded />
        </section>
        <section aria-label="Long user message">
          <UserMessage text={longUserMessage} />
        </section>
        <section aria-label="Optimistic starting turn" className="h-64 overflow-hidden">
          <Transcript
            conversation={[]}
            composerOverlay={null}
            composerHeight={0}
            streamFingerprint="optimistic-start"
            pendingUserMessage={{
              text: "Start the agent and show my prompt while setup begins.",
              attachments: []
            }}
          />
        </section>
        <section aria-label="Transcript waiting placement" className="h-64 overflow-hidden">
          <Transcript
            conversation={transcriptWaitingConversation}
            composerOverlay={null}
            composerHeight={0}
            streamFingerprint="waiting-placement"
            waitingIndicator={<WaitingBackgroundTaskIndicator tasks={waitingTasks} />}
          />
        </section>
        <section aria-label="Web search tool group">
          <ToolGroup calls={[sampleToolCalls[2]!, sampleToolCalls[1]!]} forceExpanded />
        </section>
        <section aria-label="First-call icon tool group">
          <ToolGroup calls={firstIconToolCalls} forceExpanded />
        </section>
        <section aria-label="Source fallback tool row">
          <ToolCallRow call={sampleToolCalls[2]!} forceExpanded />
        </section>
        <section aria-label="Cancelled tool row">
          <ToolCallRow call={sampleToolCalls[3]!} forceExpanded />
        </section>
        <section aria-label="User message with attachment">
          <UserMessage
            text="Can you make live attachment prompts render like macOS?"
            attachments={sampleUserAttachments}
          />
        </section>
        <section aria-label="Asserted final active turn">
          <AssistantTurn item={assertedFinalTurn.item} meta={assertedFinalTurn.meta} />
        </section>
        <section aria-label="Planned assistant turn">
          <AssistantTurn item={plannedTurn.item} meta={plannedTurn.meta} />
        </section>
        <section aria-label="Waiting background task">
          <WaitingBackgroundTaskIndicator tasks={waitingTasks} />
        </section>
        <section aria-label="User message copy">
          <UserMessage text="Can you make the Tauri chat match the macOS chat surface?" />
        </section>
        <section aria-label="Visible transcript copy buttons" className="flex items-center gap-2">
          <MessageCopyButton text="Copy message fixture" label="Copy message" />
          <MessageCopyButton text="Copy response fixture" label="Copy response" />
        </section>
        <section aria-label="Tool call group">
          <ToolGroup calls={sampleToolCalls} forceExpanded />
        </section>
      </div>
    </div>
  )
}
