import type {
  AttachmentRef,
  ConversationItem,
  PromptQueueItem,
  SessionConfigOption,
  SessionGoal
} from "@herdman/api"
import { createFileRoute } from "@tanstack/react-router"
import {
  ArrowUpIcon,
  BlocksIcon,
  Code2Icon,
  FilePlus2Icon,
  FolderIcon,
  GitBranchIcon,
  ListTodoIcon,
  TargetIcon
} from "lucide-react"
import { useMemo, useState, type ReactNode } from "react"

import { ShimmerText } from "../../components/ShimmerText"
import { Button } from "../../components/ui/button"
import { Input } from "../../components/ui/input"
import { Spinner } from "../../components/ui/spinner"
import { Switch } from "../../components/ui/switch"
import { Textarea } from "../../components/ui/textarea"
import { ChipMenu } from "../../features/composer/ChipMenu"
import { Composer } from "../../features/composer/Composer"
import { ModelConfigMenu } from "../../features/composer/ModelConfigMenu"
import { QuestionPickerCard } from "../../features/composer/QuestionPickerCard"
import { UsageRingButton } from "../../features/composer/UsageRingButton"
import {
  type ComposerAttachmentItem,
  useComposerAttachments
} from "../../features/composer/useComposerAttachments"
import { useComposerDraftText } from "../../features/composer/useComposerDraftText"
import { AssistantTurn } from "../../features/session/AssistantTurn"
import { MessageCopyButton } from "../../features/session/MessageCopyButton"
import { PlanView, TodoPanelView } from "../../features/session/PlanView"
import { PromptQueue } from "../../features/session/PromptQueue"
import {
  ComposerStatusLabel,
  GoalBanner,
  SessionHeader,
  WaitingBackgroundTaskIndicator
} from "../../features/session/SessionScreen"
import { SessionSetupView } from "../../features/session/SessionSetupView"
import { StatusBar, type TerminalPaneTab } from "../../features/session/StatusBar"
import { ToolCallRow, ToolGroup } from "../../features/session/ToolGroup"
import { Transcript, UserMessage } from "../../features/session/Transcript"
import { cn } from "../../lib/cn"
import type { TurnMeta } from "../../lib/queries"
import type {
  BackgroundTaskInfo,
  PlanEntryInfo,
  QuestionRequestInfo,
  ToolCallInfo
} from "../../lib/session-events"
import type { SessionSetupPhaseInfo } from "../../lib/session-setup"

export const Route = createFileRoute("/_shell/internal/storybook")({
  component: InternalStorybookRoute
})

const transparentPixel =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

const modelOption: SessionConfigOption = {
  id: "model",
  name: "Model",
  category: "model",
  currentValue: "opus",
  options: [
    { value: "opus", name: "Opus" },
    { value: "sonnet", name: "Sonnet" }
  ]
}

const thoughtLevelOption: SessionConfigOption = {
  id: "reasoning",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" }
  ]
}

const speedOption: SessionConfigOption = {
  id: "speed",
  name: "Speed",
  category: "speed",
  currentValue: "fast",
  options: [
    { value: "fast", name: "Fast" },
    { value: "normal", name: "Normal" }
  ]
}

const usageFixture = {
  used: 116_000,
  size: 128_000,
  costAmount: 0.12345,
  costCurrency: "USD"
}

const composerAttachments: ComposerAttachmentItem[] = [
  {
    id: "failed",
    name: "very-long-session-recording-final-cut-v7.mov",
    mimeType: "video/quicktime",
    kind: "file",
    sizeBytes: 32_000_000,
    state: "failed",
    error: "Larger than 25 MB"
  },
  {
    id: "image",
    name: "screenshot.png",
    mimeType: "image/png",
    kind: "image",
    sizeBytes: 140_000,
    previewUrl: transparentPixel,
    state: "uploaded"
  },
  {
    id: "pdf",
    name: "proposal.pdf",
    mimeType: "application/pdf",
    kind: "file",
    sizeBytes: 340_000,
    previewUrl: transparentPixel,
    state: "uploading"
  }
]

const questionRequest: QuestionRequestInfo = {
  questionId: "internal-question",
  message: "The agent needs a choice before continuing.",
  questions: [
    {
      id: "approach",
      header: "Implementation",
      question: "How should the Tauri parity work proceed?",
      options: [
        { label: "Match macOS", description: "Use the native app as source of truth" },
        { label: "Keep web defaults", description: "Prefer existing browser behavior" }
      ],
      allowsOther: true
    }
  ]
}

const setupPhases: SessionSetupPhaseInfo[] = [
  {
    id: "worktree-running",
    activeTitle: "Setting up worktree",
    completedTitle: "Set up worktree",
    failedTitle: "Could not set up worktree",
    startedAt: new Date(Date.now() - 12_000).toISOString(),
    outcome: "running",
    logs: [
      { id: 0, stream: "stderr", text: "Preparing worktree" },
      { id: 1, stream: "stdout", text: "Pulling refs" }
    ]
  },
  {
    id: "worktree-done",
    activeTitle: "Setting up worktree",
    completedTitle: "Set up worktree",
    failedTitle: "Could not set up worktree",
    startedAt: new Date(Date.now() - 64_000).toISOString(),
    endedAt: new Date(Date.now() - 4_000).toISOString(),
    outcome: "succeeded",
    logs: [{ id: 0, stream: "stdout", text: "created worktree" }]
  },
  {
    id: "worktree-failed",
    activeTitle: "Setting up worktree",
    completedTitle: "Set up worktree",
    failedTitle: "Could not set up worktree",
    startedAt: new Date(Date.now() - 8_000).toISOString(),
    endedAt: new Date(Date.now() - 1_000).toISOString(),
    outcome: "failed",
    failureMessage: "fatal: a branch named 'herdman/fix-auth' already exists",
    logs: Array.from({ length: 14 }, (_, index) => ({
      id: index,
      stream: index % 4 === 0 ? "stderr" : "stdout",
      text: `setup log ${String(index + 1).padStart(2, "0")}: preparing worktree output`
    }))
  }
]

const todos: PlanEntryInfo[] = [
  { content: "Read the existing macOS session views", priority: "high", status: "completed" },
  {
    content: "Implement the Tauri plan and todo rendering",
    priority: "medium",
    status: "in_progress"
  },
  { content: "Capture verification screenshots", priority: "low", status: "pending" }
]

const planMarkdown = `# Add goal banner

1. Extend the wire schema with \`SessionGoal\`
2. Map codex \`thread/goal/*\` in the provider
3. Render the banner above the composer

**Verification**: run the dev app and set a goal.`

const richMarkdown = `A paragraph with **bold**, *italic*, and \`inline code\`.

> Keep quote blocks aligned with the macOS transcript.

| Name | Role |
| :--- | ---: |
| Web | Renderer |

\`\`\`swift
let greeting = "Hello"
print(greeting)
\`\`\`

Done.`

const sampleToolCalls: ToolCallInfo[] = [
  {
    toolCallId: "internal-diff",
    title: "Edited Composer.tsx",
    kind: "edit",
    status: "completed",
    content: [
      {
        type: "diff",
        path: "apps/web/src/features/composer/Composer.tsx",
        oldText: "        const maxHeight = 200\n        submitOrAcceptSlash()\n",
        newText:
          "        const maxHeight = 240\n        acceptSlashWithTab()\n        submitOrAcceptSlash()\n"
      }
    ]
  },
  {
    toolCallId: "internal-shell",
    title: 'Ran rg -n "ComposerCard"',
    kind: "execute",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: "apps/macos/HerdMan/Features/Composer/ComposerView.swift:18:struct ComposerCard: View"
        }
      }
    ]
  },
  {
    toolCallId: "internal-web",
    title: "Searched SwiftUI markdown rendering",
    kind: "web_search",
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "resource_link",
          name: "Swift Markdown",
          uri: "https://github.com/apple/swift-markdown",
          title: "Swift Markdown"
        }
      }
    ]
  },
  {
    toolCallId: "internal-cancelled",
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

const userAttachments: AttachmentRef[] = [
  {
    fileId: "fixture-file",
    name: "notes.txt",
    mimeType: "text/plain",
    sizeBytes: 2048,
    kind: "file"
  }
]

const promptQueue: PromptQueueItem[] = [
  {
    id: "queued-1",
    sessionId: "internal-session",
    text: "After this finishes, summarize the implementation tradeoffs.",
    createdAt: "2026-07-08T12:00:00.000Z",
    updatedAt: "2026-07-08T12:00:00.000Z"
  },
  {
    id: "queued-2",
    sessionId: "internal-session",
    text: "Then run the chat verifier again with an expanded tool call.",
    createdAt: "2026-07-08T12:01:00.000Z",
    updatedAt: "2026-07-08T12:01:00.000Z"
  }
]

const goal: SessionGoal = {
  objective: "Match the macOS chat surface in Tauri",
  status: "active",
  tokenBudget: null,
  tokensUsed: 54_000,
  timeUsedSeconds: 90 * 60,
  createdAt: "2026-07-08T12:00:00.000Z",
  updatedAt: "2026-07-08T13:30:00.000Z"
}

const waitingTasks: BackgroundTaskInfo[] = [
  {
    id: "bg-1",
    description: "Inspect transcript rendering",
    status: "running",
    taskType: "subagent"
  },
  { id: "bg-2", description: "Run fixture capture", status: "running", taskType: "shell" }
]

const waitingConversation: ConversationItem[] = [
  {
    id: "waiting-user",
    role: "user",
    text: "Kick off the long-running verification task.",
    createdAt: "2026-07-08T12:02:00.000Z",
    isGenerating: false
  }
]

const persistenceTurnId = "persistence-assistant-8"
const persistenceConversation: ConversationItem[] = Array.from({ length: 18 }, (_, index) => {
  if (index === 8) {
    return {
      id: persistenceTurnId,
      role: "assistant",
      text: "The anchored worked section should keep its disclosure state.",
      createdAt: "2026-07-08T12:08:00.000Z",
      isGenerating: false
    }
  }
  return {
    id: `persistence-user-${index}`,
    role: "user",
    text: `Persistent transcript message ${index + 1}: keep this row in the same viewport position after navigating away and back.`,
    createdAt: `2026-07-08T12:${String(index).padStart(2, "0")}:00.000Z`,
    isGenerating: false
  }
})

const persistenceTurnMeta: Record<string, TurnMeta> = {
  [persistenceTurnId]: {
    startedAt: "2026-07-08T12:08:00.000Z",
    endedAt: "2026-07-08T12:08:12.000Z",
    thoughts: "",
    toolCalls: [sampleToolCalls[1]!],
    entries: [
      { type: "tool", call: sampleToolCalls[1]! },
      {
        type: "text",
        id: "persistence-final",
        markdown: "The anchored worked section should keep its disclosure state."
      }
    ],
    subagents: {},
    textPhases: { "persistence-final": "final" },
    nextTextId: 1
  }
}

function toolbarChips({
  goalArmed = false,
  planOn = true,
  showAgent = true
}: {
  goalArmed?: boolean
  planOn?: boolean
  showAgent?: boolean
}) {
  return (
    <>
      <ModelConfigMenu
        modelOption={modelOption}
        thoughtLevelOption={thoughtLevelOption}
        speedOption={speedOption}
        onSelect={() => undefined}
      />
      {showAgent && (
        <ChipMenu
          label="Codex"
          title="Agent"
          icon={<Code2Icon className="size-3.5" />}
          selectedValue="codex"
          options={[
            { value: "codex", label: "Codex", icon: <Code2Icon className="size-3.5" /> },
            { value: "claude", label: "Claude" }
          ]}
          onSelect={() => undefined}
        />
      )}
      <button
        type="button"
        aria-label="Plan mode"
        aria-pressed={planOn}
        className={cn(
          "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
          planOn
            ? "bg-primary/85 text-primary-foreground"
            : "text-muted-foreground hover:bg-primary/5"
        )}
      >
        <ListTodoIcon className="size-4" />
      </button>
      <button
        type="button"
        aria-label="Goal mode"
        aria-pressed={goalArmed}
        className={cn(
          "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
          goalArmed
            ? "bg-primary/85 text-primary-foreground"
            : "text-muted-foreground hover:bg-primary/5"
        )}
      >
        <TargetIcon className="size-4" />
      </button>
    </>
  )
}

function Section({
  id,
  title,
  description,
  children
}: {
  id: string
  title: string
  description?: string
  children: ReactNode
}) {
  return (
    <section id={id} className="scroll-mt-6 border-t border-[var(--herdman-separator)] pt-6">
      <div className="mb-4 flex items-start justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold">{title}</h2>
          {description != null && (
            <p className="text-muted-foreground mt-1 text-sm">{description}</p>
          )}
        </div>
        <a href={`#${id}`} className="text-muted-foreground hover:text-foreground text-xs">
          #{id}
        </a>
      </div>
      {children}
    </section>
  )
}

function StateBlock({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <h3 className="text-muted-foreground mb-2 text-xs font-semibold">{title}</h3>
      {children}
    </div>
  )
}

function SurfaceGrid({ children }: { children: ReactNode }) {
  return <div className="grid gap-4 lg:grid-cols-2">{children}</div>
}

function PlannedTurnFixture() {
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
    planDocument: planMarkdown,
    planBoundary: 2
  }
  return <AssistantTurn item={item} meta={meta} />
}

function MarkdownTurnFixture() {
  const item: ConversationItem = {
    id: "assistant-markdown",
    role: "assistant",
    text: richMarkdown,
    createdAt: "2026-07-08T12:03:00.000Z",
    isGenerating: false
  }
  const meta: TurnMeta = {
    startedAt: "2026-07-08T12:03:00.000Z",
    endedAt: "2026-07-08T12:03:08.000Z",
    thoughts: "",
    toolCalls: [],
    entries: [{ type: "text", id: "rich-markdown", markdown: richMarkdown }],
    subagents: {},
    textPhases: { "rich-markdown": "final" },
    nextTextId: 1
  }
  return <AssistantTurn item={item} meta={meta} />
}

function NestedSubagentFixture() {
  const [disclosureValues, setDisclosureValues] = useState<Record<string, boolean>>({
    "turn:assistant-nested-agents": true,
    "subagent:nested-agent-outer": true,
    "subagent:nested-agent-inner": true,
    "toolGroup:nested-agent-command": true,
    "toolCall:nested-agent-command": true
  })
  const outer: ToolCallInfo = {
    toolCallId: "nested-agent-outer",
    title: "Agent: inspect transcript parity",
    kind: "agent",
    status: "completed"
  }
  const inner: ToolCallInfo = {
    toolCallId: "nested-agent-inner",
    title: "Agent: inspect tool rendering",
    kind: "agent",
    status: "completed",
    parentToolCallId: outer.toolCallId
  }
  const child: ToolCallInfo = {
    toolCallId: "nested-agent-command",
    title: "Ran bun test",
    kind: "execute",
    status: "completed",
    parentToolCallId: inner.toolCallId,
    content: [{ type: "content", content: { type: "text", text: "91 tests passed" } }]
  }
  const item: ConversationItem = {
    id: "assistant-nested-agents",
    role: "assistant",
    text: "Nested agent verification completed.",
    createdAt: "2026-07-08T12:04:00.000Z",
    isGenerating: false
  }
  const meta: TurnMeta = {
    startedAt: "2026-07-08T12:04:00.000Z",
    endedAt: "2026-07-08T12:04:12.000Z",
    thoughts: "",
    toolCalls: [outer],
    entries: [
      { type: "tool", call: outer },
      { type: "text", id: "nested-final", markdown: item.text }
    ],
    subagents: {
      [outer.toolCallId]: {
        entries: [{ type: "tool", call: inner }],
        isThinking: false,
        nextTextId: 0
      },
      [inner.toolCallId]: {
        entries: [{ type: "tool", call: child }],
        isThinking: false,
        nextTextId: 0
      }
    },
    textPhases: { "nested-final": "final" },
    nextTextId: 1
  }
  return (
    <AssistantTurn
      item={item}
      meta={meta}
      disclosureValues={disclosureValues}
      setDisclosureValue={(key, expanded) =>
        setDisclosureValues((current) => ({ ...current, [key]: expanded }))
      }
    />
  )
}

function ComposerStates() {
  const [slashText, setSlashText] = useState("/")
  const [draftText, setDraftText] = useComposerDraftText(
    "internal-storybook-composer",
    "Follow up with the implementation details."
  )
  const [goalText, setGoalText] = useState("Ship parity for composer states")

  return (
    <SurfaceGrid>
      <StateBlock title="Normal with slash menu and attachments">
        <Composer
          value={slashText}
          onValueChange={setSlashText}
          commands={[
            { name: "review", description: "Review the current diff" },
            { name: "plan", description: "Draft a plan before editing" }
          ]}
          attachments={composerAttachments}
          usage={{ used: 62_000, size: 128_000, costAmount: 1.42, costCurrency: "USD" }}
          canSend
          chips={toolbarChips({})}
          onSend={() => undefined}
          onAttachFiles={() => undefined}
          onRemoveAttachment={() => undefined}
          onRetryAttachment={() => undefined}
        />
      </StateBlock>
      <StateBlock title="Agent running with draft">
        <Composer
          value={draftText}
          onValueChange={setDraftText}
          isSending
          canSend
          chips={toolbarChips({})}
          onStop={() => undefined}
          onSend={() => undefined}
          onAttachFiles={() => undefined}
        />
      </StateBlock>
      <StateBlock title="Agent stopping">
        <Composer
          value=""
          onValueChange={() => undefined}
          isSending
          isCancelling
          chips={toolbarChips({})}
          onStop={() => undefined}
          onSend={() => undefined}
          onAttachFiles={() => undefined}
        />
      </StateBlock>
      <StateBlock title="Retained attachment draft">
        <PersistentAttachmentFixture />
      </StateBlock>
      <StateBlock title="Submitting handoff">
        <Composer
          value="Create a branch and inspect the failing test."
          onValueChange={() => undefined}
          isSending
          canSend
          chips={toolbarChips({ planOn: false })}
          onSend={() => undefined}
          onAttachFiles={() => undefined}
        />
      </StateBlock>
      <StateBlock title="Goal edit mode">
        <Composer
          value={goalText}
          onValueChange={setGoalText}
          placeholder="Describe the goal"
          isGoalEditing
          canSend
          onEscape={() => undefined}
          onSend={() => undefined}
        />
        <div className="mt-2">
          <ComposerStatusLabel message="An attachment failed to upload. Retry or remove it, then send again." />
        </div>
      </StateBlock>
      <StateBlock title="Question picker">
        <QuestionPickerCard
          request={questionRequest}
          initialSelections={{ approach: ["Match macOS"] }}
          onAnswer={() => undefined}
          onCancel={() => undefined}
        />
      </StateBlock>
      <StateBlock title="Usage popover">
        <div className="relative h-28 px-2 pt-8">
          <UsageRingButton usage={usageFixture} forcePopover />
        </div>
      </StateBlock>
    </SurfaceGrid>
  )
}

function PersistentAttachmentFixture() {
  const [text, setText] = useComposerDraftText("internal-storybook-attachment-text")
  const attachments = useComposerAttachments("internal-storybook-attachments")

  return (
    <div className="flex flex-col gap-2">
      <Composer
        value={text}
        onValueChange={setText}
        attachments={attachments.attachments}
        canSend={text.trim() !== "" || attachments.attachments.length > 0}
        chips={toolbarChips({})}
        onSend={() => undefined}
        onAttachFiles={attachments.stageFiles}
        onRemoveAttachment={attachments.removeAttachment}
        onRetryAttachment={attachments.retryAttachment}
      />
      <Button
        type="button"
        variant="outline"
        size="icon"
        className="self-end"
        aria-label="Stage fixture attachment"
        title="Stage fixture attachment"
        onClick={() =>
          attachments.stageFiles([
            new File(["Persistent composer attachment fixture.\n"], "persistent-draft.txt", {
              type: "text/plain"
            })
          ])
        }
      >
        <FilePlus2Icon className="size-3.5" />
      </Button>
    </div>
  )
}

function PrimitiveStates() {
  const [checked, setChecked] = useState(true)

  return (
    <SurfaceGrid>
      <StateBlock title="Buttons">
        <div className="flex flex-wrap items-center gap-2">
          <Button>Default</Button>
          <Button variant="secondary">Secondary</Button>
          <Button variant="outline">Outline</Button>
          <Button variant="ghost">Ghost</Button>
          <Button variant="destructive">Destructive</Button>
          <Button size="icon" aria-label="Icon button">
            <BlocksIcon />
          </Button>
        </div>
      </StateBlock>
      <StateBlock title="Inputs and feedback">
        <div className="flex max-w-md flex-col gap-3">
          <Input placeholder="Project name" defaultValue="herdman" />
          <Textarea rows={3} placeholder="Notes" defaultValue="Jot down notes for this session." />
          <div className="flex items-center gap-3">
            <Switch checked={checked} onCheckedChange={setChecked} aria-label="Sample switch" />
            <span className="text-sm">Switch {checked ? "on" : "off"}</span>
            <Spinner />
            <ShimmerText>Streaming response...</ShimmerText>
          </div>
        </div>
      </StateBlock>
    </SurfaceGrid>
  )
}

function TranscriptStates() {
  const [todosExpanded, setTodosExpanded] = useState(true)
  const [queueExpanded, setQueueExpanded] = useState(true)
  const [persistencePinRevision, setPersistencePinRevision] = useState(0)

  return (
    <div className="flex flex-col gap-4">
      <SurfaceGrid>
        <StateBlock title="Goal banner">
          <GoalBanner
            goal={goal}
            isBusy={false}
            onPause={() => undefined}
            onResume={() => undefined}
            onEdit={() => undefined}
            onClear={() => undefined}
          />
        </StateBlock>
        <StateBlock title="Todos">
          <TodoPanelView
            entries={todos}
            isExpanded={todosExpanded}
            onToggle={() => setTodosExpanded((expanded) => !expanded)}
          />
        </StateBlock>
        <StateBlock title="Prompt queue">
          <PromptQueue
            sessionId="internal-session"
            queue={promptQueue}
            isExpanded={queueExpanded}
            onToggleExpanded={() => setQueueExpanded((expanded) => !expanded)}
          />
        </StateBlock>
        <StateBlock title="Setup phases">
          <SessionSetupView phases={setupPhases} />
        </StateBlock>
      </SurfaceGrid>
      <StateBlock title="Transcript rows">
        <div className="flex flex-col gap-5">
          <UserMessage
            text="Please compare this long path-like token inside the bubble: /Users/alexandru/repos/851-labs/herdman/apps/web/src/features/session/Transcript.tsx?with=a-very-long-query-string"
            attachments={userAttachments}
          />
          <MarkdownTurnFixture />
          <PlannedTurnFixture />
          <NestedSubagentFixture />
          <WaitingBackgroundTaskIndicator tasks={waitingTasks} />
        </div>
      </StateBlock>
      <SurfaceGrid>
        <StateBlock title="Tool group">
          <ToolGroup calls={sampleToolCalls} forceExpanded />
        </StateBlock>
        <StateBlock title="Tool rows">
          <div className="flex flex-col gap-3">
            <ToolCallRow call={sampleToolCalls[0]!} forceExpanded />
            <ToolCallRow call={sampleToolCalls[2]!} forceExpanded />
            <ToolCallRow call={sampleToolCalls[3]!} forceExpanded />
          </div>
        </StateBlock>
        <StateBlock title="Inline plan list">
          <PlanView entries={todos} />
        </StateBlock>
        <StateBlock title="Copy affordances">
          <div className="flex items-center gap-2">
            <MessageCopyButton text="Copy message fixture" label="Copy message" />
            <MessageCopyButton text="Copy response fixture" label="Copy response" />
          </div>
        </StateBlock>
      </SurfaceGrid>
      <StateBlock title="Transcript placement fixtures">
        <div className="grid gap-4 lg:grid-cols-2">
          <div className="h-64 overflow-hidden border border-[var(--herdman-separator)]">
            <Transcript
              conversation={[]}
              composerOverlay={null}
              composerHeight={0}
              streamFingerprint="internal-optimistic"
              pendingUserMessage={{
                text: "Start the agent and show my prompt while setup begins.",
                attachments: []
              }}
            />
          </div>
          <div className="h-64 overflow-hidden border border-[var(--herdman-separator)]">
            <Transcript
              conversation={waitingConversation}
              composerOverlay={null}
              composerHeight={0}
              streamFingerprint="internal-waiting"
              waitingIndicator={<WaitingBackgroundTaskIndicator tasks={waitingTasks} />}
            />
          </div>
        </div>
      </StateBlock>
      <StateBlock title="Session persistence">
        <div className="flex flex-col gap-2">
          <div className="flex h-64 overflow-hidden border border-[var(--herdman-separator)]">
            <Transcript
              conversation={persistenceConversation}
              turnMeta={persistenceTurnMeta}
              composerOverlay={null}
              composerHeight={0}
              streamFingerprint="internal-persistence"
              persistenceKey="internal-transcript-persistence-v2"
              pinRevision={persistencePinRevision}
            />
          </div>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="self-end"
            aria-label="Simulate user send"
            title="Simulate user send"
            onClick={() => setPersistencePinRevision((revision) => revision + 1)}
          >
            <ArrowUpIcon className="size-3.5" strokeWidth={3} />
          </Button>
        </div>
      </StateBlock>
    </div>
  )
}

function ChromeStates() {
  const panes: TerminalPaneTab[] = [
    { id: "terminal-1", name: "Terminal 1" },
    { id: "server", name: "Server", attachOnly: true },
    { id: "tests", name: "Tests" }
  ]

  return (
    <SurfaceGrid>
      <StateBlock title="Session header">
        <div className="overflow-hidden border border-[var(--herdman-separator)]">
          <SessionHeader
            title="Implement macOS chat parity"
            diffTotals={{ added: 128, removed: 34 }}
          />
          <div className="h-20 bg-[var(--herdman-card-quiet-bg)]" />
        </div>
      </StateBlock>
      <StateBlock title="Bottom pane bar">
        <div className="overflow-hidden rounded-md border border-[var(--herdman-separator)]">
          <StatusBar
            terminalVisible
            panes={panes}
            selectedPaneId="server"
            onToggleTerminal={() => undefined}
            onResizeTerminal={() => undefined}
            onSelectPane={() => undefined}
            onClosePane={() => undefined}
            onAddTerminalPane={() => undefined}
          />
          <div className="bg-[var(--herdman-card-quiet-bg)] p-4 font-mono text-xs text-muted-foreground">
            $ bun run test
          </div>
        </div>
      </StateBlock>
      <StateBlock title="New chat accessory strip">
        <div>
          <Composer
            value=""
            onValueChange={() => undefined}
            placeholder="Do anything"
            chips={toolbarChips({ showAgent: false })}
            onSend={() => undefined}
            onAttachFiles={() => undefined}
          />
          <div className="flex items-center gap-3 rounded-b-2xl border border-t-0 border-[var(--herdman-card-border)] bg-[var(--herdman-card-bg)] px-3.5 pt-7 pb-2 text-sm">
            <ChipMenu
              label="Codex"
              title="Agent"
              icon={<Code2Icon className="size-3.5" />}
              selectedValue="codex"
              options={[
                { value: "codex", label: "Codex", icon: <Code2Icon className="size-3.5" /> },
                { value: "claude", label: "Claude" }
              ]}
              onSelect={() => undefined}
            />
            <ChipMenu
              label="Project directory"
              title="Where this chat's commands run"
              icon={<FolderIcon className="size-3.5 fill-current" />}
              selectedValue="project"
              options={[
                {
                  value: "project",
                  label: "Project directory",
                  icon: <FolderIcon className="size-3.5 fill-current" />
                },
                {
                  value: "worktree",
                  label: "New worktree",
                  icon: <GitBranchIcon className="size-3.5" />
                }
              ]}
              onSelect={() => undefined}
            />
          </div>
        </div>
      </StateBlock>
    </SurfaceGrid>
  )
}

function InternalStorybookRoute() {
  const sections = useMemo(
    () =>
      [
        ["primitives", "Primitives"],
        ["composer", "Composer"],
        ["transcript", "Transcript"],
        ["chrome", "Chrome"]
      ] as const,
    []
  )

  return (
    <div className="bg-background h-full overflow-auto">
      <div className="mx-auto flex w-full max-w-[1180px] flex-col gap-8 px-6 pt-24 pb-8">
        <header className="flex flex-col gap-4">
          <div className="flex items-center gap-2">
            <BlocksIcon className="text-muted-foreground size-5" />
            <h1 className="text-2xl font-semibold">Internal UI</h1>
          </div>
          <p className="text-muted-foreground max-w-3xl text-sm">
            A kitchen sink for HerdMan UI states. Use this page to inspect common controls,
            transcript rows, tool calls, composer modes, and app chrome without needing a live
            session in a particular state.
          </p>
          <nav className="flex flex-wrap gap-2">
            {sections.map(([id, label]) => (
              <a
                key={id}
                href={`#${id}`}
                className="text-muted-foreground hover:bg-accent hover:text-foreground rounded-md px-2 py-1 text-xs"
              >
                {label}
              </a>
            ))}
          </nav>
        </header>

        <Section
          id="primitives"
          title="Primitives"
          description="Shared low-level controls and feedback states."
        >
          <PrimitiveStates />
        </Section>

        <Section
          id="composer"
          title="Composer"
          description="Toolbar chips, attachments, stop/send, slash commands, usage, goal mode, and questions."
        >
          <ComposerStates />
        </Section>

        <Section
          id="transcript"
          title="Transcript"
          description="User rows, assistant turns, tool calls, plans, setup phases, queues, and waiting states."
        >
          <TranscriptStates />
        </Section>

        <Section id="chrome" title="Chrome" description="Surfaces around the main chat body.">
          <ChromeStates />
        </Section>
      </div>
    </div>
  )
}
