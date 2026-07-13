import type {
  BranchDiffTotals,
  ConversationItem,
  QuestionAnswerEntry,
  SessionConfigOption,
  SessionGoal,
  SessionModeState
} from "@herdman/api"
import {
  HistoryIcon,
  ListTodoIcon,
  PauseIcon,
  PencilIcon,
  PlayIcon,
  TargetIcon,
  TriangleAlertIcon,
  XIcon
} from "lucide-react"
import { type DragEvent, type ReactNode, useEffect, useMemo, useState } from "react"

import { ShimmerText } from "../../components/ShimmerText"
import { Spinner } from "../../components/ui/spinner"
import { cn } from "../../lib/cn"
import type { BackgroundTaskInfo, QuestionRequestInfo } from "../../lib/session-events"
import { useElementHeight } from "../../lib/useElementHeight"
import {
  useAnswerSessionQuestion,
  useCancelSession,
  useCapabilities,
  usePromptSession,
  useSessionDetail,
  useSessionBranchDiff,
  useClearSessionGoal,
  useSetSessionConfig,
  useSetSessionGoal,
  useSetSessionMode,
  useProjects
} from "../../lib/queries"
import { withDeferredAgentPhase } from "../../lib/session-setup"
import { ChipMenu } from "../composer/ChipMenu"
import { Composer } from "../composer/Composer"
import { ModelConfigMenu } from "../composer/ModelConfigMenu"
import { QuestionPickerCard } from "../composer/QuestionPickerCard"
import { useComposerAttachments } from "../composer/useComposerAttachments"
import { useComposerDraftText } from "../composer/useComposerDraftText"
import { DropToAttachOverlay } from "../attachments/AttachmentPreview"
import { useIsSessionRunning } from "../sidebar/SessionRow"
import { TerminalPanel } from "../terminal/TerminalPanel"
import { TodoPanelView } from "./PlanView"
import { PromptQueue } from "./PromptQueue"
import { StatusBar, type TerminalPaneTab } from "./StatusBar"
import { Transcript } from "./Transcript"
import { projectFolderPath } from "../../lib/client"
import { DiffCounter } from "./DiffCounter"
import { usePlanApprovalDismissal } from "./usePlanApprovalDismissal"
import { useTodoExpansionState } from "./useTodoExpansionState"

const MIN_TERMINAL_HEIGHT = 120
const MAX_TERMINAL_HEIGHT = 800
const DEFAULT_TERMINAL_HEIGHT = 280
const PLAN_APPROVAL_QUESTION_ID = "codex-plan-approval"
const EXIT_PLAN_MODE_QUESTION_ID = "exit_plan_mode"
const IMPLEMENT_PLAN_LABEL = "Implement plan"
const KEEP_PLANNING_LABEL = "Keep planning"
const MODEL_MENU_CATEGORIES = new Set(["model", "thought_level", "speed"])

export function SessionHeader({
  title,
  diffTotals
}: {
  title: string
  diffTotals?: BranchDiffTotals | null
}) {
  const showsDiff = diffTotals != null && (diffTotals.added > 0 || diffTotals.removed > 0)
  return (
    <header className="border-border-opaque flex h-9 shrink-0 items-center gap-2 border-b px-3">
      <h1 className="min-w-0 truncate text-sm font-semibold" aria-label="Session title">
        {title}
      </h1>
      {showsDiff && <DiffCounter totals={diffTotals} />}
    </header>
  )
}

export function answersImplementPlan(answers: Record<string, QuestionAnswerEntry>) {
  return answers[EXIT_PLAN_MODE_QUESTION_ID]?.answers[0] === IMPLEMENT_PLAN_LABEL
}

export function sessionTurnIsRunning(
  serverIsRunning: boolean,
  conversation: readonly { isGenerating: boolean }[]
): boolean {
  return serverIsRunning || conversation.some((item) => item.isGenerating)
}

export function retryPromptForTurn(
  conversation: readonly ConversationItem[],
  assistantItemId: string
): ConversationItem | undefined {
  const assistantIndex = conversation.findIndex((item) => item.id === assistantItemId)
  if (assistantIndex < 1) return undefined
  return conversation
    .slice(0, assistantIndex)
    .reverse()
    .find((item) => item.role === "user")
}

type PlanControl =
  | { kind: "mode"; planId: string; buildId: string }
  | { kind: "config"; optionId: string; planValue: string; buildValue: string }

function flattenConfigOptions(option: SessionConfigOption) {
  return option.options.flatMap((entry) => ("group" in entry ? entry.options : [entry]))
}

function matches(pattern: string, ...candidates: string[]) {
  const regex = new RegExp(pattern, "i")
  return candidates.some((candidate) => regex.test(candidate))
}

function modeConfigOption(options: readonly SessionConfigOption[]) {
  return options.find((option) => option.category === "mode" || option.id === "mode")
}

function planControlFor({
  modes,
  configOptions
}: {
  modes: SessionModeState | undefined
  configOptions: readonly SessionConfigOption[]
}): PlanControl | undefined {
  const plan = modes?.availableModes.find((mode) => mode.canonicalId === "plan")
  const build =
    modes?.availableModes.find((mode) => mode.canonicalId === "fullAccess") ??
    modes?.availableModes.find((mode) => mode.canonicalId !== "plan")
  if (plan != null && build != null) {
    return { kind: "mode", planId: plan.id, buildId: build.id }
  }

  const option = modeConfigOption(configOptions)
  if (option == null) return undefined
  const values = flattenConfigOptions(option)
  const planValue = values.find((value) => matches("^plan", value.value, value.name))
  const buildValue =
    values.find((value) => matches("bypass|full[-_ ]?access|yolo", value.value, value.name)) ??
    values.find((value) => value.value !== planValue?.value)
  if (planValue == null || buildValue == null) return undefined
  return {
    kind: "config",
    optionId: option.id,
    planValue: planValue.value,
    buildValue: buildValue.value
  }
}

// The active session screen: streaming transcript with the composer floating
// over the bottom, the status bar underneath, and the optional terminal panel
// (SessionView.swift SessionScreen).
export function SessionScreen({ sessionId }: { sessionId: string }) {
  const detailQuery = useSessionDetail(sessionId)
  const branchDiffQuery = useSessionBranchDiff(sessionId)
  const projectsQuery = useProjects()
  const promptSession = usePromptSession()
  const cancelSession = useCancelSession()
  const answerQuestion = useAnswerSessionQuestion()
  const setGoal = useSetSessionGoal()
  const clearGoal = useClearSessionGoal()
  const setMode = useSetSessionMode()
  const setConfig = useSetSessionConfig()
  const serverIsRunning = useIsSessionRunning(sessionId)
  const detail = detailQuery.data
  const todosAreCompleted =
    detail == null
      ? undefined
      : detail.sessionPlan != null &&
        detail.sessionPlan.length > 0 &&
        detail.sessionPlan.every((entry) => entry.status === "completed")

  const [composerText, setComposerText] = useComposerDraftText(`session:${sessionId}`)
  const [composerError, setComposerError] = useState<string>()
  const [isCancelling, setIsCancelling] = useState(false)
  const [paneState, setPaneState] = useState(() => loadTerminalPaneState(sessionId))
  const [isGoalComposerArmed, setIsGoalComposerArmed] = useState(false)
  const [isGoalEditing, setIsGoalEditing] = useState(false)
  const [isTodosExpanded, setIsTodosExpanded] = useTodoExpansionState(sessionId, todosAreCompleted)
  const [isQueueExpanded, setIsQueueExpanded] = useState(true)
  const [dismissedPlanApprovalKey, setDismissedPlanApprovalKey] =
    usePlanApprovalDismissal(sessionId)
  const [composerSendRevision, setComposerSendRevision] = useState(0)
  const [mountedTerminalPaneIds, setMountedTerminalPaneIds] = useState<string[]>([])
  const [isAttachmentDropTargeted, setIsAttachmentDropTargeted] = useState(false)
  const [composerRef, composerHeight] = useElementHeight()
  const composerAttachments = useComposerAttachments(`session:${sessionId}`)
  const terminalVisible = paneState.isVisible
  const terminalHeight = paneState.height
  const selectedPane = paneState.panes.find((pane) => pane.id === paneState.selectedPaneId)

  const isRunning = sessionTurnIsRunning(serverIsRunning, detail?.conversation ?? [])
  const project = projectsQuery.data?.find(
    (candidate) => candidate.id === detail?.session.projectId
  )

  // Mode + config pickers come from the harness capability (matching the
  // Swift ConfigPrefetcher), with the live mode following stream updates.
  const capabilitiesQuery = useCapabilities(
    project == null ? undefined : projectFolderPath(project)
  )
  const capability = capabilitiesQuery.data?.harnesses.find(
    (candidate) => candidate.harness.id === detail?.session.harnessId
  )
  const currentModeId = detail?.currentModeId ?? capability?.modes?.currentModeId
  const currentMode = capability?.modes?.availableModes.find((mode) => mode.id === currentModeId)
  const supportsGoals = capability?.supportsGoals === true
  const harnessName = capability?.harness.name ?? detail?.session.harnessId ?? "agent"
  const configOptions = detail?.configOptions ?? capability?.configOptions ?? []
  const modelOption = configOptions.find((option) => option.category === "model")
  const thoughtLevelOption = configOptions.find((option) => option.category === "thought_level")
  const speedOption = configOptions.find((option) => option.category === "speed")
  const pickerOptions = configOptions.filter(
    (option) =>
      option.category !== "mode" &&
      option.id !== "mode" &&
      !MODEL_MENU_CATEGORIES.has(option.category ?? "")
  )
  const planControl = useMemo(
    () => planControlFor({ modes: capability?.modes, configOptions }),
    [capability?.modes, configOptions]
  )
  const isPlanModeOn =
    planControl?.kind === "mode"
      ? currentModeId === planControl.planId
      : planControl?.kind === "config"
        ? configOptions.find((option) => option.id === planControl.optionId)?.currentValue ===
          planControl.planValue
        : currentMode?.canonicalId === "plan"
  const setupPhases = useMemo(() => {
    const phases = detail?.setupPhases ?? []
    const startedAt =
      phases.find((phase) => phase.id === "worktree")?.endedAt ??
      detail?.conversation[0]?.createdAt ??
      detail?.session.createdAt ??
      new Date().toISOString()
    return withDeferredAgentPhase(phases, {
      hasDeferredAgent: detail?.session.agentSessionId === "",
      agentName: harnessName,
      startedAt
    })
  }, [detail?.conversation, detail?.session, detail?.setupPhases, harnessName])

  const streamFingerprint = useMemo(() => {
    const conversation = detail?.conversation ?? []
    const last = conversation[conversation.length - 1]
    const lastMeta = last != null ? detail?.turnMeta?.[last.id] : undefined
    return [
      conversation.length,
      last?.text.length ?? 0,
      last?.isGenerating ?? false,
      lastMeta?.thoughts.length ?? 0,
      lastMeta?.toolCalls.length ?? 0,
      lastMeta?.entries.length ?? 0,
      Object.values(lastMeta?.subagents ?? {})
        .map((bucket) => `${bucket.entries.length}.${bucket.isThinking ? 1 : 0}`)
        .join(","),
      detail?.runningSubagentToolCallIds?.join(",") ?? "",
      setupPhases?.map((phase) => `${phase.id}.${phase.outcome}.${phase.logs.length}`).join(",") ??
        ""
    ].join(":")
  }, [detail, setupPhases])

  // ⌘J toggles the terminal panel.
  useEffect(() => {
    const handler = (keyEvent: KeyboardEvent) => {
      if (keyEvent.key === "j" && (keyEvent.metaKey || keyEvent.ctrlKey)) {
        keyEvent.preventDefault()
        setPaneState((state) => ({
          ...ensureTerminalPane(state, sessionId),
          isVisible: !state.isVisible
        }))
      }
    }
    window.addEventListener("keydown", handler)
    return () => window.removeEventListener("keydown", handler)
  }, [sessionId])

  const exitGoalComposer = () => {
    setIsGoalComposerArmed(false)
    setIsGoalEditing(false)
    setComposerText("")
    setComposerError(undefined)
    composerAttachments.clearAttachments()
  }

  const toggleGoalComposer = () => {
    if (isGoalComposerArmed) {
      exitGoalComposer()
      return
    }
    setIsGoalComposerArmed(true)
    setIsGoalEditing(false)
    setComposerError(undefined)
    composerAttachments.clearAttachments()
  }

  const editGoal = () => {
    if (detail?.goal == null) return
    setComposerText(detail.goal.objective)
    setIsGoalComposerArmed(true)
    setIsGoalEditing(true)
    setComposerError(undefined)
    composerAttachments.clearAttachments()
  }

  const submitGoal = async () => {
    const objective = composerText.trim()
    if (objective === "" || !supportsGoals) return
    setComposerError(undefined)
    try {
      await setGoal.mutateAsync({ id: sessionId, objective })
      setComposerText("")
      setIsGoalComposerArmed(false)
      setIsGoalEditing(false)
    } catch (goalError) {
      setComposerError(goalError instanceof Error ? goalError.message : String(goalError))
    }
  }

  const send = async () => {
    if (isGoalComposerArmed) {
      await submitGoal()
      return
    }
    const text = composerText
    if (text.trim() === "" && composerAttachments.attachments.length === 0) return
    setComposerError(undefined)
    try {
      const attachments = await composerAttachments.collectForSend()
      const trimmedText = text.trim()
      setComposerText("")
      setComposerSendRevision((revision) => revision + 1)
      await promptSession.mutateAsync({ id: sessionId, text: trimmedText, attachments })
      composerAttachments.clearAttachments()
    } catch (sendError) {
      setComposerText(text)
      setComposerError(sendError instanceof Error ? sendError.message : String(sendError))
    }
  }

  const retryTurn = async (assistantItemId: string) => {
    if (detail == null || isRunning || promptSession.isPending) return
    const prompt = retryPromptForTurn(detail.conversation, assistantItemId)
    if (prompt == null) return
    setComposerError(undefined)
    setComposerSendRevision((revision) => revision + 1)
    try {
      await promptSession.mutateAsync({
        id: sessionId,
        text: prompt.text,
        attachments: prompt.attachments
      })
    } catch (retryError) {
      setComposerError(retryError instanceof Error ? retryError.message : String(retryError))
    }
  }

  const stop = async () => {
    if (!isRunning || isCancelling) return
    setComposerError(undefined)
    setIsCancelling(true)
    try {
      await cancelSession.mutateAsync(sessionId)
    } catch (cancelError) {
      setIsCancelling(false)
      setComposerError(cancelError instanceof Error ? cancelError.message : String(cancelError))
    }
  }

  useEffect(() => {
    if (!isRunning) setIsCancelling(false)
  }, [isRunning])

  useEffect(() => {
    setIsCancelling(false)
  }, [sessionId])

  useEffect(() => {
    setPaneState(loadTerminalPaneState(sessionId))
  }, [sessionId])

  useEffect(() => {
    if (paneState.sessionId === sessionId) saveTerminalPaneState(sessionId, paneState)
  }, [sessionId, paneState])

  useEffect(() => {
    if (!terminalVisible || selectedPane == null) return
    setMountedTerminalPaneIds((ids) =>
      ids.includes(selectedPane.id) ? ids : [...ids, selectedPane.id]
    )
  }, [selectedPane, terminalVisible])

  useEffect(() => {
    const liveIds = new Set(paneState.panes.map((pane) => pane.id))
    setMountedTerminalPaneIds((ids) => ids.filter((id) => liveIds.has(id)))
  }, [paneState.panes])

  useEffect(() => {
    const taskPanes = (detail?.backgroundTasks ?? [])
      .filter((task) => task.terminalKey != null)
      .map((task) => ({
        id: `agent:${task.terminalKey}`,
        name: task.description,
        terminalKey: task.terminalKey!,
        attachOnly: true
      }))

    setPaneState((state) => {
      const taskKeys = new Set(taskPanes.map((pane) => pane.terminalKey))
      const userPanes = state.panes.filter((pane) => !pane.attachOnly)
      const existingTaskPanes = state.panes.filter(
        (pane) => pane.attachOnly && taskKeys.has(pane.terminalKey)
      )
      const nextTaskPanes = [
        ...existingTaskPanes.map((pane) => {
          const taskPane = taskPanes.find((candidate) => candidate.terminalKey === pane.terminalKey)
          return taskPane == null ? pane : { ...pane, name: taskPane.name }
        }),
        ...taskPanes.filter(
          (taskPane) => !existingTaskPanes.some((pane) => pane.terminalKey === taskPane.terminalKey)
        )
      ]
      const panes = [...userPanes, ...nextTaskPanes]
      const selectedPaneId = panes.some((pane) => pane.id === state.selectedPaneId)
        ? state.selectedPaneId
        : panes[0]?.id

      if (
        panes.length === state.panes.length &&
        selectedPaneId === state.selectedPaneId &&
        panes.every((pane, index) => sameTerminalPane(pane, state.panes[index]))
      ) {
        return state
      }

      return {
        ...state,
        panes,
        selectedPaneId,
        isVisible: panes.length > 0 && state.isVisible
      }
    })
  }, [detail?.backgroundTasks])

  const lastAssistant = detail?.conversation
    .slice()
    .reverse()
    .find((item) => item.role === "assistant")
  const lastAssistantMeta = lastAssistant == null ? undefined : detail?.turnMeta?.[lastAssistant.id]
  const planApprovalKey =
    lastAssistant != null && lastAssistantMeta?.planDocument != null
      ? `${lastAssistant.id}:${lastAssistantMeta.planDocument}`
      : undefined
  const planApprovalRequest: QuestionRequestInfo | undefined =
    detail?.pendingQuestion == null &&
    detail?.session.harnessId === "codex" &&
    isPlanModeOn &&
    lastAssistant != null &&
    !lastAssistant.isGenerating &&
    lastAssistantMeta?.planDocument != null &&
    lastAssistantMeta.planDocument !== "" &&
    planApprovalKey !== dismissedPlanApprovalKey
      ? {
          questionId: PLAN_APPROVAL_QUESTION_ID,
          questions: [
            {
              id: EXIT_PLAN_MODE_QUESTION_ID,
              header: "Plan",
              question: "Ready to implement this plan?",
              options: [
                { label: IMPLEMENT_PLAN_LABEL, description: "Start building" },
                { label: KEEP_PLANNING_LABEL, description: "Keep refining in plan mode" }
              ],
              allowsOther: false
            }
          ]
        }
      : undefined

  const leavePlanMode = async () => {
    if (planControl?.kind === "mode") {
      await setMode.mutateAsync({ id: sessionId, modeId: planControl.buildId })
    } else if (planControl?.kind === "config") {
      await setConfig.mutateAsync({
        id: sessionId,
        configId: planControl.optionId,
        value: planControl.buildValue
      })
    }
  }

  const resolvePlanApproval = async (answers: Record<string, QuestionAnswerEntry>) => {
    if (planApprovalKey != null) setDismissedPlanApprovalKey(planApprovalKey)
    const entry = answers[EXIT_PLAN_MODE_QUESTION_ID]
    const note = entry?.note?.trim() ?? ""
    const selected = entry?.answers[0]
    if (selected === IMPLEMENT_PLAN_LABEL) {
      await leavePlanMode()
      const text = note === "" ? "Implement the plan." : `Implement the plan.\n\n${note}`
      await promptSession.mutateAsync({ id: sessionId, text })
    } else if (note !== "") {
      await promptSession.mutateAsync({ id: sessionId, text: note })
    }
  }

  if (detail == null) {
    return (
      <div className="flex h-full items-center justify-center">
        {detailQuery.isError ? (
          <p className="flex items-center gap-2 text-sm text-[var(--herdman-status-error)]">
            <TriangleAlertIcon className="size-4" />
            {detailQuery.error instanceof Error ? detailQuery.error.message : "Failed to load"}
          </p>
        ) : (
          <Spinner />
        )}
      </div>
    )
  }

  const activeQuestion = detail.pendingQuestion ?? planApprovalRequest
  const usage = detail.liveUsage ?? {
    used: detail.session.usage?.used,
    size: detail.session.usage?.size,
    costAmount: detail.session.usage?.costAmount,
    costCurrency: detail.session.usage?.costCurrency
  }
  const waitingBackgroundTasks = isRunning
    ? []
    : (detail.backgroundTasks ?? []).filter((task) => task.terminalKey == null)
  const composerStatusMessage = composerError ?? composerAttachments.error
  const isGoalBusy = setGoal.isPending || clearGoal.isPending
  const canAcceptDroppedFiles = activeQuestion == null && !isGoalComposerArmed

  const handleAttachmentDragOver = (event: DragEvent<HTMLDivElement>) => {
    if (event.defaultPrevented || !canAcceptDroppedFiles) return
    if (!event.dataTransfer.types.includes("Files")) return
    event.preventDefault()
    setIsAttachmentDropTargeted(true)
  }

  const handleAttachmentDragLeave = (event: DragEvent<HTMLDivElement>) => {
    if (event.currentTarget !== event.target) return
    setIsAttachmentDropTargeted(false)
  }

  const handleAttachmentDrop = (event: DragEvent<HTMLDivElement>) => {
    if (event.defaultPrevented || !canAcceptDroppedFiles) return
    const files = Array.from(event.dataTransfer.files)
    if (files.length === 0) return
    event.preventDefault()
    setIsAttachmentDropTargeted(false)
    composerAttachments.stageFiles(files)
  }

  const goalModeButton =
    supportsGoals && !isGoalEditing ? (
      <button
        type="button"
        aria-label="Goal mode"
        title="Goal mode"
        aria-pressed={isGoalComposerArmed}
        onClick={toggleGoalComposer}
        className={cn(
          "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
          isGoalComposerArmed
            ? "bg-primary/85 text-primary-foreground hover:bg-primary/95"
            : "text-muted-foreground hover:bg-primary/5 hover:text-foreground"
        )}
      >
        <TargetIcon className="size-4" />
      </button>
    ) : null
  const planModeButton =
    planControl != null && !isGoalEditing ? (
      <button
        type="button"
        aria-label="Plan mode"
        title="Toggle plan mode"
        aria-pressed={isPlanModeOn}
        disabled={setMode.isPending || setConfig.isPending}
        onClick={() => {
          if (planControl.kind === "mode") {
            setMode.mutate({
              id: sessionId,
              modeId: isPlanModeOn ? planControl.buildId : planControl.planId
            })
          } else {
            setConfig.mutate({
              id: sessionId,
              configId: planControl.optionId,
              value: isPlanModeOn ? planControl.buildValue : planControl.planValue
            })
          }
        }}
        className={cn(
          "flex size-7 cursor-default items-center justify-center rounded-full outline-none disabled:opacity-50",
          isPlanModeOn
            ? "bg-primary/85 text-primary-foreground hover:bg-primary/95"
            : "text-muted-foreground hover:bg-primary/5 hover:text-foreground"
        )}
      >
        <ListTodoIcon className="size-4" />
      </button>
    ) : null

  const composerOverlay = (
    <div ref={composerRef} className="relative mx-auto max-w-[880px] px-6 pt-6 pb-4">
      <div className="flex flex-col gap-2">
        {detail.sessionPlan != null && detail.sessionPlan.length > 0 && (
          <TodoPanelView
            entries={detail.sessionPlan}
            isExpanded={isTodosExpanded}
            onToggle={() => setIsTodosExpanded(!isTodosExpanded)}
          />
        )}
        {supportsGoals && detail.goal != null && !isGoalEditing && (
          <GoalBanner
            goal={detail.goal}
            isBusy={isGoalBusy}
            onPause={() => setGoal.mutate({ id: sessionId, status: "paused" })}
            onResume={() => setGoal.mutate({ id: sessionId, status: "active" })}
            onEdit={editGoal}
            onClear={() => {
              if (window.confirm(`Clear this goal?\n\n${detail.goal?.objective ?? ""}`)) {
                clearGoal.mutate(sessionId)
              }
            }}
          />
        )}
        {detail.promptQueue.length > 0 && (
          <PromptQueue
            sessionId={sessionId}
            queue={detail.promptQueue}
            isExpanded={isQueueExpanded}
            onToggleExpanded={() => setIsQueueExpanded((expanded) => !expanded)}
          />
        )}
        {activeQuestion != null ? (
          <QuestionPickerCard
            request={activeQuestion}
            isSubmitting={
              answerQuestion.isPending ||
              promptSession.isPending ||
              setMode.isPending ||
              setConfig.isPending
            }
            onAnswer={(answers) => {
              if (detail.pendingQuestion == null) {
                void resolvePlanApproval(answers)
                return
              }
              const pendingQuestion = detail.pendingQuestion
              void (async () => {
                if (answersImplementPlan(answers) && isPlanModeOn) await leavePlanMode()
                answerQuestion.mutate({
                  id: sessionId,
                  questionId: pendingQuestion.questionId,
                  outcome: "answered",
                  answers
                })
              })()
            }}
            onCancel={() => {
              if (detail.pendingQuestion == null) {
                if (planApprovalKey != null) setDismissedPlanApprovalKey(planApprovalKey)
                return
              }
              answerQuestion.mutate({
                id: sessionId,
                questionId: detail.pendingQuestion.questionId,
                outcome: "cancelled"
              })
            }}
          />
        ) : (
          <Composer
            value={composerText}
            onValueChange={setComposerText}
            placeholder={isGoalComposerArmed ? "Describe the goal" : "Ask for follow-up changes"}
            autoFocus
            focusOnTyping
            commands={detail.availableCommands ?? []}
            attachments={isGoalComposerArmed ? [] : composerAttachments.attachments}
            usage={usage}
            canSend={
              isGoalComposerArmed
                ? composerText.trim() !== "" && !setGoal.isPending
                : composerText.trim() !== "" || composerAttachments.attachments.length > 0
            }
            isSending={isGoalComposerArmed ? setGoal.isPending : isRunning}
            isCancelling={!isGoalComposerArmed && isCancelling}
            isGoalEditing={isGoalEditing}
            onAttachFiles={isGoalComposerArmed ? undefined : composerAttachments.stageFiles}
            onRemoveAttachment={
              isGoalComposerArmed ? undefined : composerAttachments.removeAttachment
            }
            onRetryAttachment={
              isGoalComposerArmed ? undefined : composerAttachments.retryAttachment
            }
            onSend={() => void send()}
            onEscape={isGoalComposerArmed ? exitGoalComposer : undefined}
            onStop={isGoalComposerArmed ? undefined : () => void stop()}
            chips={
              <>
                {!isGoalEditing && (
                  <ModelConfigMenu
                    modelOption={modelOption}
                    thoughtLevelOption={thoughtLevelOption}
                    speedOption={speedOption}
                    onSelect={(configId, value) =>
                      setConfig.mutate({ id: sessionId, configId, value })
                    }
                  />
                )}
                {!isGoalEditing &&
                  pickerOptions.map((option) => {
                    const flatOptions = flattenConfigOptions(option)
                    const current = flatOptions.find(
                      (candidate) => candidate.value === option.currentValue
                    )
                    return (
                      <ChipMenu
                        key={option.id}
                        title={option.name}
                        label={current?.name ?? option.currentValue}
                        options={flatOptions.map((entry) => ({
                          value: entry.value,
                          label: entry.name
                        }))}
                        selectedValue={option.currentValue}
                        onSelect={(value) =>
                          setConfig.mutate({ id: sessionId, configId: option.id, value })
                        }
                      />
                    )
                  })}
                {planModeButton}
                {goalModeButton}
              </>
            }
          />
        )}
        {composerStatusMessage != null && <ComposerStatusLabel message={composerStatusMessage} />}
      </div>
    </div>
  )

  return (
    <div
      className="bg-background relative flex h-full flex-col overflow-hidden"
      onDragOver={handleAttachmentDragOver}
      onDragLeave={handleAttachmentDragLeave}
      onDrop={handleAttachmentDrop}
    >
      <SessionHeader title={detail.session.title} diffTotals={branchDiffQuery.data} />
      <Transcript
        key={sessionId}
        conversation={detail.conversation}
        turnMeta={detail.turnMeta}
        errorMessage={detail.streamError}
        composerOverlay={composerOverlay}
        waitingIndicator={
          waitingBackgroundTasks.length > 0 ? (
            <WaitingBackgroundTaskIndicator tasks={waitingBackgroundTasks} />
          ) : null
        }
        composerHeight={composerHeight}
        streamFingerprint={streamFingerprint}
        setupPhases={setupPhases}
        runningSubagentToolCallIds={detail.runningSubagentToolCallIds}
        persistenceKey={sessionId}
        pinRevision={composerSendRevision}
        onRetryTurn={(itemId) => void retryTurn(itemId)}
        retryPending={isRunning || promptSession.isPending}
      />
      <StatusBar
        terminalVisible={terminalVisible}
        panes={paneState.panes}
        selectedPaneId={paneState.selectedPaneId}
        onToggleTerminal={() =>
          setPaneState((state) => ({
            ...ensureTerminalPane(state, sessionId),
            isVisible: !state.isVisible
          }))
        }
        onResizeTerminal={(deltaY) =>
          setPaneState((state) => ({
            ...state,
            height: clampTerminalHeight(state.height + deltaY)
          }))
        }
        onSelectPane={(id) =>
          setPaneState((state) => ({
            ...state,
            selectedPaneId: id,
            isVisible: true
          }))
        }
        onClosePane={(id) =>
          setPaneState((state) => {
            const index = state.panes.findIndex((pane) => pane.id === id)
            if (index < 0) return state
            const panes = state.panes.filter((pane) => pane.id !== id)
            const selectedPaneId =
              state.selectedPaneId === id
                ? panes[Math.min(index, panes.length - 1)]?.id
                : state.selectedPaneId
            return {
              ...state,
              panes,
              selectedPaneId,
              isVisible: panes.length > 0 && state.isVisible
            }
          })
        }
        onAddTerminalPane={() =>
          setPaneState((state) => {
            const pane = makeTerminalPane(sessionId, nextTerminalName(state.panes))
            return {
              ...state,
              panes: [...state.panes, pane],
              selectedPaneId: pane.id,
              isVisible: true
            }
          })
        }
      />
      {project != null && mountedTerminalPaneIds.length > 0 && (
        <div
          style={{ height: terminalVisible ? terminalHeight : 0 }}
          className={cn("shrink-0 overflow-hidden", !terminalVisible && "pointer-events-none")}
        >
          {paneState.panes
            .filter((pane) => mountedTerminalPaneIds.includes(pane.id))
            .map((pane) => (
              <div
                key={pane.id}
                className={cn("h-full w-full", pane.id !== selectedPane?.id && "hidden")}
              >
                <TerminalPanel
                  sessionId={pane.terminalKey}
                  cwd={detail?.session.cwd ?? projectFolderPath(project) ?? ""}
                  attachOnly={pane.attachOnly}
                />
              </div>
            ))}
        </div>
      )}
      {isAttachmentDropTargeted && canAcceptDroppedFiles && <DropToAttachOverlay />}
    </div>
  )
}

interface TerminalPaneState {
  sessionId: string
  panes: TerminalPane[]
  selectedPaneId: string | undefined
  isVisible: boolean
  height: number
}

interface TerminalPane extends TerminalPaneTab {
  terminalKey: string
  attachOnly?: boolean
}

function initialTerminalPaneState(sessionId: string): TerminalPaneState {
  const pane = makeInitialTerminalPane(sessionId)
  return {
    sessionId,
    panes: [pane],
    selectedPaneId: pane.id,
    isVisible: false,
    height: DEFAULT_TERMINAL_HEIGHT
  }
}

function loadTerminalPaneState(sessionId: string): TerminalPaneState {
  const fallback = initialTerminalPaneState(sessionId)
  if (typeof window === "undefined") return fallback
  try {
    const raw = window.localStorage.getItem(terminalPaneStorageKey(sessionId))
    if (raw == null) return fallback
    const parsed = JSON.parse(raw) as Partial<TerminalPaneState>
    const panes = Array.isArray(parsed.panes) ? parsed.panes.filter(isTerminalPane) : fallback.panes
    const safePanes = panes.length > 0 ? panes : fallback.panes
    return {
      sessionId,
      panes: safePanes,
      selectedPaneId: safePanes.some((pane) => pane.id === parsed.selectedPaneId)
        ? parsed.selectedPaneId
        : safePanes[0]?.id,
      isVisible: parsed.isVisible === true,
      height: clampTerminalHeight(
        typeof parsed.height === "number" ? parsed.height : DEFAULT_TERMINAL_HEIGHT
      )
    }
  } catch {
    return fallback
  }
}

function saveTerminalPaneState(sessionId: string, state: TerminalPaneState) {
  if (typeof window === "undefined") return
  const userPanes = state.panes.filter((pane) => !pane.attachOnly)
  const selectedPaneId = userPanes.some((pane) => pane.id === state.selectedPaneId)
    ? state.selectedPaneId
    : userPanes[0]?.id
  window.localStorage.setItem(
    terminalPaneStorageKey(sessionId),
    JSON.stringify({
      panes: userPanes,
      selectedPaneId,
      isVisible: state.isVisible,
      height: state.height
    })
  )
}

function ensureTerminalPane(state: TerminalPaneState, sessionId: string): TerminalPaneState {
  if (state.panes.length > 0) return state
  const pane = makeInitialTerminalPane(sessionId)
  return { ...state, panes: [pane], selectedPaneId: pane.id }
}

function makeInitialTerminalPane(sessionId: string): TerminalPane {
  return { id: `terminal:${sessionId}`, name: "Terminal 1", terminalKey: sessionId }
}

function makeTerminalPane(sessionId: string, name: string): TerminalPane {
  const id = crypto.randomUUID()
  return { id, name, terminalKey: `${sessionId}:${id}` }
}

function nextTerminalName(panes: readonly TerminalPane[]) {
  const highest = panes
    .filter((pane) => !pane.attachOnly)
    .map((pane) => /^Terminal (\d+)$/.exec(pane.name)?.[1])
    .filter((value): value is string => value != null)
    .map((value) => Number.parseInt(value, 10))
    .reduce((max, value) => Math.max(max, value), 0)
  return `Terminal ${highest + 1}`
}

function isTerminalPane(value: unknown): value is TerminalPane {
  if (value == null || typeof value !== "object") return false
  const pane = value as Partial<TerminalPane>
  return (
    typeof pane.id === "string" &&
    typeof pane.name === "string" &&
    typeof pane.terminalKey === "string" &&
    (pane.attachOnly == null || typeof pane.attachOnly === "boolean")
  )
}

function sameTerminalPane(left: TerminalPane, right: TerminalPane | undefined): boolean {
  return (
    right != null &&
    left.id === right.id &&
    left.name === right.name &&
    left.terminalKey === right.terminalKey &&
    left.attachOnly === right.attachOnly
  )
}

function clampTerminalHeight(height: number): number {
  return Math.min(MAX_TERMINAL_HEIGHT, Math.max(MIN_TERMINAL_HEIGHT, height))
}

function terminalPaneStorageKey(sessionId: string): string {
  return `herdman.terminalPanes.${sessionId}`
}

export function WaitingBackgroundTaskIndicator({
  tasks
}: {
  tasks: readonly BackgroundTaskInfo[]
}) {
  const task = tasks[0]
  if (task == null) return null
  const label = waitingBackgroundTaskLabel(tasks)

  return (
    <div className="flex items-center gap-2">
      <HistoryIcon className="text-muted-foreground size-4 shrink-0" />
      <ShimmerText>{label}</ShimmerText>
      <span className="flex-1" />
    </div>
  )
}

export function waitingBackgroundTaskLabel(
  tasks: readonly Pick<BackgroundTaskInfo, "description">[]
) {
  const task = tasks[0]
  if (task == null) return ""
  const extra = tasks.length - 1
  return extra > 0 ? `${task.description} and ${extra} more` : task.description
}

export function ComposerStatusLabel({ message }: { message: string }) {
  return (
    <p className="flex items-center gap-1.5 text-sm text-[var(--herdman-status-warn)]">
      <TriangleAlertIcon className="size-4 shrink-0" />
      <span>{message}</span>
    </p>
  )
}

export function GoalBanner({
  goal,
  isBusy,
  onPause,
  onResume,
  onEdit,
  onClear
}: {
  goal: SessionGoal
  isBusy: boolean
  onPause: () => void
  onResume: () => void
  onEdit: () => void
  onClear: () => void
}) {
  const parts = [
    goal.tokensUsed > 0 ? `${formatTokenCount(goal.tokensUsed)} tokens` : undefined,
    goal.timeUsedSeconds > 0 ? formatElapsed(goal.timeUsedSeconds) : undefined
  ].filter((part): part is string => part != null)
  const canResume = goal.status !== "active" && goal.status !== "complete"

  return (
    <div
      aria-label={`Goal: ${goal.objective}, ${goalStatusText(goal.status)}`}
      className="flex items-start gap-2.5 rounded-lg border border-[var(--herdman-separator)] bg-[var(--herdman-card-bg)] p-2.5"
    >
      <TargetIcon className="text-muted-foreground mt-[3px] size-3.5 shrink-0" />
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-start gap-2">
          <p className="line-clamp-2 text-sm font-medium">{goal.objective}</p>
          <span
            className={cn(
              "mt-0.5 shrink-0 rounded-full bg-[color-mix(in_srgb,currentColor_15%,transparent)] px-1.5 py-0.5 text-[11px] font-semibold",
              isTroubleGoalStatus(goal.status)
                ? "text-[var(--herdman-status-warn)]"
                : goal.status === "active"
                  ? "text-foreground"
                  : "text-muted-foreground"
            )}
          >
            {goalStatusText(goal.status)}
          </span>
        </div>
        {parts.length > 0 && (
          <p className="text-muted-foreground/80 mt-0.5 font-mono text-xs">{parts.join(" · ")}</p>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-1.5">
        {goal.status === "active" ? (
          <GoalIconButton label="Pause goal" disabled={isBusy} onClick={onPause}>
            <PauseIcon className="size-3.5 fill-current" />
          </GoalIconButton>
        ) : canResume ? (
          <GoalIconButton label="Resume goal" disabled={isBusy} onClick={onResume}>
            <PlayIcon className="size-3.5 fill-current" />
          </GoalIconButton>
        ) : null}
        <GoalIconButton
          label="Edit goal - loads it into the composer"
          disabled={isBusy}
          onClick={onEdit}
        >
          <PencilIcon className="size-3.5" />
        </GoalIconButton>
        <GoalIconButton label="Clear goal" disabled={isBusy} onClick={onClear}>
          <XIcon className="size-4" />
        </GoalIconButton>
      </div>
    </div>
  )
}

function GoalIconButton({
  label,
  disabled,
  onClick,
  children
}: {
  label: string
  disabled?: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
      className="text-muted-foreground hover:text-foreground flex size-5 cursor-default items-center justify-center outline-none disabled:opacity-50"
    >
      {children}
    </button>
  )
}

function goalStatusText(status: SessionGoal["status"]): string {
  switch (status) {
    case "active":
      return "Active"
    case "paused":
      return "Paused"
    case "blocked":
      return "Blocked"
    case "usageLimited":
      return "Usage limited"
    case "budgetLimited":
      return "Budget limited"
    case "complete":
      return "Complete"
  }
}

function isTroubleGoalStatus(status: SessionGoal["status"]): boolean {
  return status === "blocked" || status === "usageLimited" || status === "budgetLimited"
}

export function formatTokenCount(count: number): string {
  if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`
  if (count >= 1_000) return `${(count / 1_000).toFixed(1).replace(/\.0$/, "")}k`
  return `${count}`
}

export function formatElapsed(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) {
    const rest = minutes % 60
    return rest === 0 ? `${hours}h` : `${hours}h ${rest}m`
  }
  return `${Math.floor(hours / 24)}d ${hours % 24}h ${minutes % 60}m`
}
