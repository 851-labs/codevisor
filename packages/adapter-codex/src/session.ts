import type { QuestionSpec, SessionGoal } from "@codevisor/api"
import type {
  BackgroundTerminalIntegration,
  ExternalTerminalStream,
  QuestionAnswer,
  RuntimeEmit
} from "@codevisor/agent-runtime"
import type { CodexClient } from "./client.js"
import type { CodexCommandKiller } from "./process-kill.js"

export interface CodexModel {
  readonly value: string
  readonly name: string
  readonly efforts: ReadonlyArray<string>
  readonly defaultEffort: string
  /// Whether the model's service tiers include the fast ("priority") tier.
  readonly supportsFast: boolean
  /// Whether the model's catalog default service tier is the fast tier.
  readonly defaultsToFast: boolean
}

/// One blocking server→client ask awaiting the human's answer — either the
/// model's `item/tool/requestUserInput` or an MCP server's
/// `mcpServer/elicitation/request`. `resolve`/`reject` settle the held
/// JSON-RPC handler promise; `respond` builds the source-specific reply from
/// the wire answers; `cancelResponse` is the source-specific dismissal reply
/// (undefined = reject the JSON-RPC request instead).
export interface PendingCodexQuestion {
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (response: unknown) => void
  readonly reject: (error: Error) => void
  readonly timer: NodeJS.Timeout | undefined
  readonly respond: (answers: NonNullable<QuestionAnswer["answers"]>) => unknown
  readonly cancelResponse?: unknown
}

/// One in-flight command execution's terminal mirror. `promoted` flips when
/// the command outlives the promotion delay — that is when it appears in the
/// `backgroundTasks` snapshot (and therefore as a tab).
export interface CodexCommandTerminal {
  readonly itemId: string
  readonly terminalKey: string
  readonly description: string
  readonly stream: ExternalTerminalStream
  promoted: boolean
  promotionTimer: NodeJS.Timeout | undefined
}

export interface CodexSession {
  readonly key: string
  readonly threadId: string
  readonly client: CodexClient
  readonly emit: RuntimeEmit
  readonly cwd: string
  activeTurnId: string | undefined
  pendingTurnError: { message: string; retryable: boolean } | undefined
  pendingPrompt: { resolve: (value: { stopReason: string }) => void } | undefined
  interruptRequested: boolean
  lastHarnessTitle: string | undefined
  currentModel: string
  currentEffort: string | undefined
  /// Undefined until the user picks a speed — the model's default tier applies.
  currentSpeed: "standard" | "fast" | undefined
  currentModeId: string
  /// True once a Plan-mode turn has run. Codex's collaboration mode is sticky
  /// server-side, so after engaging Plan we keep sending an explicit
  /// collaboration mode every turn ("default" leaves Plan) instead of omitting
  /// it — otherwise the model stays in Plan mode after the toggle flips off.
  collaborationEngaged: boolean
  models: ReadonlyArray<CodexModel>
  /// item id → tool-call kind, so completions map back without re-parsing.
  readonly itemKinds: Map<string, string>
  /// agentMessage item id → wire phase ("commentary" | "final"), captured from
  /// `item/started` so every streamed delta carries the message's finality.
  /// Codex tags items with `phase: "commentary" | "final_answer"` when the
  /// model emits harmony channels; untagged items stay unknown and clients
  /// fall back to optimistic (last-text-wins) rendering.
  readonly messagePhases: Map<string, "commentary" | "final">
  /// Collab (sub)agent thread id → the spawnAgent tool call id that created
  /// it. Items arriving on those threads are tagged with that parent so
  /// clients can nest them; the main thread's id is `threadId`.
  readonly collabThreads: Map<string, string>
  /// item id → human-readable title, so approval prompts can say WHAT is
  /// being approved (approval params carry only the item id).
  readonly itemTitles: Map<string, string>
  /// Read-only terminal mirrors for in-flight command executions, keyed by
  /// item id. Codex owns the processes; we own the mirrors.
  readonly commandTerminals: Map<string, CodexCommandTerminal>
  readonly backgroundTerminals: BackgroundTerminalIntegration | undefined
  readonly killCommandProcesses: CodexCommandKiller
  /// Goal-snapshot throttle state: the last snapshot broadcast to the wire,
  /// when it went out, and the freshest one held back by the rate limit
  /// (flushed at turn end so final totals always persist).
  lastEmittedGoal: SessionGoal | undefined
  lastGoalEmitAtMs: number
  pendingGoalSnapshot: SessionGoal | undefined
  /// question id (= codex item id) → held requestUserInput handler.
  readonly pendingQuestions: Map<string, PendingCodexQuestion>
}
