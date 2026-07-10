import type { SessionConfigOption, SessionModeState } from "@herdman/api"
import { useNavigate } from "@tanstack/react-router"
import {
  Code2Icon,
  FolderIcon,
  GitBranchIcon,
  ListTodoIcon,
  MousePointer2Icon,
  SparklesIcon,
  TargetIcon,
  TriangleAlertIcon
} from "lucide-react"
import { type DragEvent, useEffect, useMemo, useRef, useState } from "react"

import { useApi } from "../../lib/api"
import { cn } from "../../lib/cn"
import { projectFolderPath } from "../../lib/client"
import {
  useCapabilities,
  useCreateSession,
  useCreateWorktree,
  useHarnesses,
  usePromptSession,
  useProjects,
  useSetSessionConfig,
  useSetSessionMode,
  useSetSessionGoal,
  useUpdateSession
} from "../../lib/queries"
import {
  applyWorktreeSetupEvent,
  failRunningSetupPhases,
  type SessionSetupPhaseInfo,
  worktreePhase
} from "../../lib/session-setup"
import { ChipMenu } from "../composer/ChipMenu"
import { Composer } from "../composer/Composer"
import { ModelConfigMenu } from "../composer/ModelConfigMenu"
import { useComposerAttachments } from "../composer/useComposerAttachments"
import { useComposerDraftText } from "../composer/useComposerDraftText"
import { DropToAttachOverlay } from "../attachments/AttachmentPreview"
import { SessionSetupView } from "../session/SessionSetupView"
import { ProjectMenu } from "./ProjectMenu"
import {
  moveNewChatDraftToProject,
  rememberNewChatSessionDefaults,
  updateNewChatDraftState,
  useNewChatDraftState
} from "./useNewChatDraftState"

const MODEL_MENU_CATEGORIES = new Set(["model", "thought_level", "speed"])
const REMEMBERED_CONFIG_CATEGORIES = new Set([...MODEL_MENU_CATEGORIES, "model_config"])

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

function harnessChipIcon(symbolName: string | undefined) {
  const className = "size-3.5"
  switch (symbolName) {
    case "sparkle":
      return <SparklesIcon className={className} />
    case "cursorarrow.rays":
      return <MousePointer2Icon className={className} />
    case "chevron.left.forwardslash.chevron.right":
      return <Code2Icon className={className} />
    default:
      return <Code2Icon className={className} />
  }
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
  if (plan != null && build != null) return { kind: "mode", planId: plan.id, buildId: build.id }

  const option = configOptions.find(
    (candidate) => candidate.category === "mode" || candidate.id === "mode"
  )
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

// The session title from the first prompt: its first line, capped at 48
// characters (NewChatView.swift title(from:)).
export function sessionTitleFrom(prompt: string): string {
  const trimmed = prompt.trim()
  const firstLine = trimmed.split("\n", 1)[0] ?? ""
  if (firstLine === "") return "New session"
  return firstLine.length > 48 ? `${firstLine.slice(0, 48)}…` : firstLine
}

// The new-chat page: a centered "What should we build in <project>?" title
// with an inline project dropdown, and the composer. The session is created
// only when the user sends (NewChatView.swift).
export function NewChatScreen({ preferredProjectId }: { preferredProjectId?: string }) {
  const navigate = useNavigate()
  const { client, events } = useApi()
  const projectsQuery = useProjects()
  const harnessesQuery = useHarnesses()
  const createSession = useCreateSession()
  const createWorktree = useCreateWorktree()
  const promptSession = usePromptSession()
  const setGoal = useSetSessionGoal()
  const setMode = useSetSessionMode()
  const setConfig = useSetSessionConfig()
  const updateSession = useUpdateSession()

  const draft = useNewChatDraftState()
  const [text, setText] = useComposerDraftText("new-chat")
  const [isAttachmentDropTargeted, setIsAttachmentDropTargeted] = useState(false)
  const hasInitializedProject = useRef(false)
  const composerAttachments = useComposerAttachments("new-chat")
  const {
    selectedProjectId,
    selectedHarnessId,
    runInWorktree,
    pendingModeId,
    isGoalComposerArmed,
    error,
    setupWorktreeId,
    setupPhases
  } = draft

  const projects = useMemo(
    () => (projectsQuery.data ?? []).filter((project) => !project.isArchived),
    [projectsQuery.data]
  )
  const selectedProject =
    projects.find((project) => project.id === selectedProjectId) ?? projects[0]
  const capabilitiesQuery = useCapabilities(
    selectedProject == null ? undefined : projectFolderPath(selectedProject)
  )

  const harnesses = useMemo(
    () => (harnessesQuery.data ?? []).filter((harness) => harness.enabled),
    [harnessesQuery.data]
  )
  const selectedHarness =
    harnesses.find((harness) => harness.id === selectedHarnessId) ??
    harnesses.find((harness) => harness.readiness.state === "ready") ??
    harnesses[0]
  const selectedCapability = capabilitiesQuery.data?.harnesses.find(
    (candidate) => candidate.harness.id === selectedHarness?.id
  )
  const pendingConfig =
    selectedHarness == null ? {} : (draft.configByHarness[selectedHarness.id] ?? {})
  const supportsGoals = selectedCapability?.supportsGoals === true
  const worktreeAvailable =
    selectedProject?.locations.some((location) => location.isGitRepository === true) === true
  const configOptions = useMemo(
    () =>
      (selectedCapability?.configOptions ?? []).map((option) => {
        const pending = pendingConfig[option.id]
        if (pending == null) return option
        const values = flattenConfigOptions(option)
        return values.length > 0 && !values.some((value) => value.value === pending)
          ? option
          : { ...option, currentValue: pending }
      }),
    [selectedCapability?.configOptions, pendingConfig]
  )
  const currentModeId = pendingModeId ?? selectedCapability?.modes?.currentModeId
  const planControl = useMemo(
    () => planControlFor({ modes: selectedCapability?.modes, configOptions }),
    [selectedCapability?.modes, configOptions]
  )
  const isPlanModeOn =
    planControl?.kind === "mode"
      ? currentModeId === planControl.planId
      : planControl?.kind === "config"
        ? configOptions.find((option) => option.id === planControl.optionId)?.currentValue ===
          planControl.planValue
        : false
  const modelOption = configOptions.find((option) => option.category === "model")
  const thoughtLevelOption = configOptions.find((option) => option.category === "thought_level")
  const speedOption = configOptions.find((option) => option.category === "speed")
  const pickerOptions = configOptions.filter(
    (option) =>
      option.category !== "mode" &&
      option.id !== "mode" &&
      !MODEL_MENU_CATEGORIES.has(option.category ?? "")
  )

  useEffect(() => {
    if (hasInitializedProject.current || projects.length === 0) return
    hasInitializedProject.current = true
    const explicitProject = projects.find((project) => project.id === preferredProjectId)
    const retainedProject = projects.find((project) => project.id === selectedProjectId)
    const project = explicitProject ?? retainedProject ?? projects[0]
    if (project == null) return
    const supportsWorktrees = project.locations.some(
      (location) => location.isGitRepository === true
    )
    updateNewChatDraftState((current) =>
      moveNewChatDraftToProject(current, project.id, supportsWorktrees)
    )
  }, [preferredProjectId, projects, selectedProjectId])

  useEffect(() => {
    if (selectedHarness == null || selectedHarness.id === selectedHarnessId) return
    updateNewChatDraftState((current) => ({
      ...current,
      selectedHarnessId: selectedHarness.id,
      pendingModeId: undefined
    }))
  }, [selectedHarness, selectedHarnessId])

  useEffect(() => {
    if (selectedCapability == null || supportsGoals || !isGoalComposerArmed) return
    updateNewChatDraftState((current) => ({ ...current, isGoalComposerArmed: false }))
  }, [isGoalComposerArmed, selectedCapability, supportsGoals])

  useEffect(() => {
    if (setupWorktreeId == null) return
    return events.subscribe((event) => {
      updateNewChatDraftState((current) => ({
        ...current,
        setupPhases: applyWorktreeSetupEvent(current.setupPhases, event, setupWorktreeId)
      }))
    })
  }, [events, setupWorktreeId])

  const setError = (value: string | undefined) => {
    updateNewChatDraftState((current) => ({ ...current, error: value }))
  }
  const setIsGoalComposerArmed = (value: boolean) => {
    updateNewChatDraftState((current) => ({ ...current, isGoalComposerArmed: value }))
  }
  const setRunInWorktree = (value: boolean) => {
    updateNewChatDraftState((current) => ({ ...current, runInWorktree: value }))
  }
  const setPendingModeId = (value: string | undefined) => {
    updateNewChatDraftState((current) => ({ ...current, pendingModeId: value }))
  }
  const setSetupWorktreeId = (value: string | undefined) => {
    updateNewChatDraftState((current) => ({ ...current, setupWorktreeId: value }))
  }
  const setSetupPhases = (
    update:
      | SessionSetupPhaseInfo[]
      | ((current: SessionSetupPhaseInfo[]) => SessionSetupPhaseInfo[])
  ) => {
    updateNewChatDraftState((current) => ({
      ...current,
      setupPhases: typeof update === "function" ? update(current.setupPhases) : update
    }))
  }
  const setPendingConfig = (
    update: Record<string, string> | ((current: Record<string, string>) => Record<string, string>)
  ) => {
    if (selectedHarness == null) return
    updateNewChatDraftState((current) => {
      const existing = current.configByHarness[selectedHarness.id] ?? {}
      const next = typeof update === "function" ? update(existing) : update
      return {
        ...current,
        configByHarness: { ...current.configByHarness, [selectedHarness.id]: next }
      }
    })
  }

  const exitGoalComposer = () => {
    setIsGoalComposerArmed(false)
    setText("")
    setError(undefined)
    composerAttachments.clearAttachments()
  }

  const toggleGoalComposer = () => {
    if (isGoalComposerArmed) {
      exitGoalComposer()
      return
    }
    setIsGoalComposerArmed(true)
    setError(undefined)
    composerAttachments.clearAttachments()
  }

  const send = async () => {
    if (
      selectedProject == null ||
      selectedHarness == null ||
      (isGoalComposerArmed
        ? text.trim() === "" || !supportsGoals
        : text.trim() === "" && composerAttachments.attachments.length === 0)
    ) {
      return
    }
    setError(undefined)
    const trimmedText = text.trim()
    let createdSessionId: string | undefined
    try {
      const attachments = isGoalComposerArmed
        ? undefined
        : await composerAttachments.collectForSend()
      const session = await createSession.mutateAsync({
        projectId: selectedProject.id,
        harnessId: selectedHarness.id,
        title: sessionTitleFrom(trimmedText),
        deferAgentSession: true
      })
      createdSessionId = session.id
      setText("")
      void navigate({ to: "/session/$sessionId", params: { sessionId: session.id } })

      const worktreeId = runInWorktree ? crypto.randomUUID() : undefined
      if (worktreeId != null) {
        setSetupWorktreeId(worktreeId)
        setSetupPhases([worktreePhase(new Date().toISOString())])
      }
      const worktree = runInWorktree
        ? await createWorktree.mutateAsync({
            projectId: selectedProject.id,
            request: { id: worktreeId, sessionId: session.id }
          })
        : undefined
      if (worktree != null) {
        await updateSession.mutateAsync({
          id: session.id,
          request: { worktreeName: worktree.name }
        })
      }
      if (pendingModeId != null) {
        await setMode.mutateAsync({ id: session.id, modeId: pendingModeId })
      }
      for (const [configId, value] of Object.entries(pendingConfig)) {
        await setConfig.mutateAsync({ id: session.id, configId, value })
      }
      if (isGoalComposerArmed) {
        await setGoal.mutateAsync({ id: session.id, objective: trimmedText })
      } else {
        await promptSession.mutateAsync({ id: session.id, text: trimmedText, attachments })
        composerAttachments.clearAttachments()
      }
      rememberNewChatSessionDefaults({
        selectedHarnessId: selectedHarness.id,
        runInWorktree,
        config: Object.fromEntries(
          configOptions
            .filter((option) => REMEMBERED_CONFIG_CATEGORIES.has(option.category ?? ""))
            .map((option) => [option.id, option.currentValue])
        )
      })
    } catch (sendError) {
      const message = sendError instanceof Error ? sendError.message : String(sendError)
      if (createdSessionId != null) {
        await client.deleteSession(createdSessionId).catch(() => undefined)
        void navigate({ to: "/" })
        setText(trimmedText)
      }
      setError(message)
      setSetupPhases((current) =>
        current.length === 0
          ? current
          : failRunningSetupPhases(current, message, new Date().toISOString())
      )
    }
  }

  const canAcceptDroppedFiles = projects.length > 0 && !isGoalComposerArmed

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

  return (
    <div
      className="relative flex h-full items-center justify-center overflow-hidden p-4 pb-24"
      onDragOver={handleAttachmentDragOver}
      onDragLeave={handleAttachmentDragLeave}
      onDrop={handleAttachmentDrop}
    >
      <div className="flex w-full max-w-[720px] flex-col items-center gap-[22px]">
        {projects.length === 0 ? (
          <div className="flex flex-col items-center gap-2.5 text-center">
            <h1 className="text-[26px] font-semibold">Add a project to start</h1>
            <p className="text-muted-foreground">Use the + next to projects in the sidebar.</p>
          </div>
        ) : (
          <h1 className="text-center text-[26px] leading-relaxed font-semibold text-balance">
            What should we build in{" "}
            <ProjectMenu
              projects={projects}
              selected={selectedProject}
              onSelect={(project) => {
                const supportsWorktrees = project.locations.some(
                  (location) => location.isGitRepository === true
                )
                updateNewChatDraftState((current) =>
                  moveNewChatDraftToProject(current, project.id, supportsWorktrees)
                )
              }}
            />
            ?
          </h1>
        )}
        {projects.length > 0 && (
          <div className="w-full">
            <Composer
              value={text}
              onValueChange={setText}
              autoFocus
              placeholder={isGoalComposerArmed ? "Describe the goal" : "Do anything"}
              attachments={isGoalComposerArmed ? [] : composerAttachments.attachments}
              canSend={
                isGoalComposerArmed
                  ? text.trim() !== "" && supportsGoals
                  : text.trim() !== "" || composerAttachments.attachments.length > 0
              }
              isSending={
                createSession.isPending ||
                createWorktree.isPending ||
                promptSession.isPending ||
                setGoal.isPending ||
                setMode.isPending ||
                setConfig.isPending ||
                updateSession.isPending
              }
              onAttachFiles={isGoalComposerArmed ? undefined : composerAttachments.stageFiles}
              onRemoveAttachment={
                isGoalComposerArmed ? undefined : composerAttachments.removeAttachment
              }
              onRetryAttachment={
                isGoalComposerArmed ? undefined : composerAttachments.retryAttachment
              }
              onSend={() => void send()}
              onEscape={isGoalComposerArmed ? exitGoalComposer : undefined}
              chips={
                <>
                  <ModelConfigMenu
                    modelOption={modelOption}
                    thoughtLevelOption={thoughtLevelOption}
                    speedOption={speedOption}
                    onSelect={(configId, value) =>
                      setPendingConfig((current) => ({ ...current, [configId]: value }))
                    }
                  />
                  {pickerOptions.map((option) => {
                    const flatOptions = flattenConfigOptions(option)
                    const current = flatOptions.find(
                      (candidate) => candidate.value === option.currentValue
                    )
                    return (
                      <ChipMenu
                        key={option.id}
                        label={current?.name ?? option.currentValue}
                        title={option.name}
                        options={flatOptions.map((entry) => ({
                          value: entry.value,
                          label: entry.name
                        }))}
                        selectedValue={option.currentValue}
                        onSelect={(value) =>
                          setPendingConfig((current) => ({ ...current, [option.id]: value }))
                        }
                      />
                    )
                  })}
                  {planControl != null && (
                    <button
                      type="button"
                      aria-label="Plan mode"
                      title="Toggle plan mode"
                      aria-pressed={isPlanModeOn}
                      onClick={() => {
                        if (planControl.kind === "mode") {
                          setPendingModeId(isPlanModeOn ? planControl.buildId : planControl.planId)
                        } else {
                          setPendingConfig((current) => ({
                            ...current,
                            [planControl.optionId]: isPlanModeOn
                              ? planControl.buildValue
                              : planControl.planValue
                          }))
                        }
                      }}
                      className={cn(
                        "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
                        isPlanModeOn
                          ? "bg-primary/85 text-primary-foreground hover:bg-primary/95"
                          : "text-muted-foreground hover:bg-primary/5 hover:text-foreground"
                      )}
                    >
                      <ListTodoIcon className="size-4" />
                    </button>
                  )}
                  {supportsGoals && (
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
                  )}
                </>
              }
            />
            <div className="-mt-4 flex items-center gap-3 rounded-b-2xl border border-t-0 border-[var(--herdman-card-border)] bg-[var(--herdman-card-bg)] px-3.5 pt-7 pb-2 text-sm">
              {harnesses.length === 0 ? (
                <span className="text-muted-foreground">No agent installed</span>
              ) : (
                <ChipMenu
                  label={selectedHarness?.name ?? "Choose agent"}
                  title="Agent"
                  icon={harnessChipIcon(selectedHarness?.symbolName)}
                  options={harnesses.map((harness) => ({
                    value: harness.id,
                    label: harness.name,
                    icon: harnessChipIcon(harness.symbolName)
                  }))}
                  selectedValue={selectedHarness?.id}
                  onSelect={(harnessId) => {
                    updateNewChatDraftState((current) => ({
                      ...current,
                      selectedHarnessId: harnessId,
                      pendingModeId: undefined,
                      error: undefined
                    }))
                  }}
                />
              )}
              <ChipMenu
                label={runInWorktree ? "New worktree" : "Project directory"}
                title={
                  worktreeAvailable
                    ? "Where this chat's commands run"
                    : "Worktrees need the project folder to be a git repository"
                }
                icon={
                  runInWorktree ? (
                    <GitBranchIcon className="size-3.5" />
                  ) : (
                    <FolderIcon className="size-3.5 fill-current" />
                  )
                }
                options={[
                  {
                    value: "project",
                    label: "Project directory",
                    icon: <FolderIcon className="size-3.5 fill-current" />
                  },
                  {
                    value: "worktree",
                    label: "New worktree",
                    icon: <GitBranchIcon className="size-3.5" />,
                    disabled: !worktreeAvailable,
                    description: worktreeAvailable ? undefined : "Requires a git repository"
                  }
                ]}
                selectedValue={runInWorktree ? "worktree" : "project"}
                onSelect={(value) => setRunInWorktree(value === "worktree")}
              />
            </div>
            <div className="mt-3">
              <SessionSetupView phases={setupPhases} />
            </div>
          </div>
        )}
        {(error ?? composerAttachments.error) != null && (
          <p className="flex items-center gap-1.5 text-sm text-[var(--herdman-status-warn)]">
            <TriangleAlertIcon className="size-4" />
            {error ?? composerAttachments.error}
          </p>
        )}
      </div>
      {isAttachmentDropTargeted && canAcceptDroppedFiles && <DropToAttachOverlay />}
    </div>
  )
}
