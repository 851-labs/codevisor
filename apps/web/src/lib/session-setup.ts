import {
  decode,
  type EventEnvelope,
  WorktreeSetupUpdate,
  type WorktreeSetupUpdate as WorktreeSetupUpdateType
} from "@codevisor/api"

export interface SessionSetupLogLineInfo {
  id: number
  stream: string
  text: string
}

export type SessionSetupOutcome = "running" | "succeeded" | "failed"

export interface SessionSetupPhaseInfo {
  id: string
  activeTitle: string
  completedTitle: string
  failedTitle: string
  startedAt: string
  endedAt?: string
  outcome: SessionSetupOutcome
  failureMessage?: string
  logs: SessionSetupLogLineInfo[]
}

const decodeWorktreeSetupUpdate = decode(WorktreeSetupUpdate)

export const WORKTREE_SETUP_PHASE_ID = "worktree"
export const AGENT_SETUP_PHASE_ID = "agent"

export function worktreePhase(startedAt: string): SessionSetupPhaseInfo {
  return {
    id: WORKTREE_SETUP_PHASE_ID,
    activeTitle: "Setting up worktree",
    completedTitle: "Set up worktree",
    failedTitle: "Could not set up worktree",
    startedAt,
    outcome: "running",
    logs: []
  }
}

export function agentPhase(name: string, startedAt: string): SessionSetupPhaseInfo {
  return {
    id: AGENT_SETUP_PHASE_ID,
    activeTitle: `Starting ${name}`,
    completedTitle: `Started ${name}`,
    failedTitle: `Could not start ${name}`,
    startedAt,
    outcome: "running",
    logs: []
  }
}

export function withDeferredAgentPhase(
  phases: readonly SessionSetupPhaseInfo[],
  {
    hasDeferredAgent,
    agentName,
    startedAt
  }: { hasDeferredAgent: boolean; agentName: string; startedAt: string }
): SessionSetupPhaseInfo[] {
  if (!hasDeferredAgent) return [...phases]
  if (phases.some((phase) => phase.id === AGENT_SETUP_PHASE_ID)) return [...phases]
  if (phases.some((phase) => phase.id === WORKTREE_SETUP_PHASE_ID && phase.outcome === "running")) {
    return [...phases]
  }
  return [...phases, agentPhase(agentName, startedAt)]
}

export function worktreeSetupUpdateFrom(
  event: EventEnvelope,
  worktreeId: string
): WorktreeSetupUpdateType | undefined {
  if (event.kind !== "worktree.setup") return undefined
  if (event.subjectId.toLowerCase() !== worktreeId.toLowerCase()) return undefined
  try {
    const update = decodeWorktreeSetupUpdate(event.payload)
    return update.worktreeId.toLowerCase() === worktreeId.toLowerCase() ? update : undefined
  } catch {
    return undefined
  }
}

export function worktreeSetupUpdateForName(
  event: EventEnvelope,
  worktreeName: string | undefined
): WorktreeSetupUpdateType | undefined {
  if (worktreeName == null || event.kind !== "worktree.setup") return undefined
  try {
    const update = decodeWorktreeSetupUpdate(event.payload)
    return update.name === worktreeName ? update : undefined
  } catch {
    return undefined
  }
}

export function worktreeSetupUpdateForSession(
  event: EventEnvelope,
  sessionId: string
): WorktreeSetupUpdateType | undefined {
  if (event.kind !== "worktree.setup") return undefined
  if (event.subjectId.toLowerCase() !== sessionId.toLowerCase()) return undefined
  try {
    return decodeWorktreeSetupUpdate(event.payload)
  } catch {
    return undefined
  }
}

export function applyWorktreeSetupEvent(
  phases: readonly SessionSetupPhaseInfo[],
  event: EventEnvelope,
  worktreeId: string
): SessionSetupPhaseInfo[] {
  const update = worktreeSetupUpdateFrom(event, worktreeId)
  return applyWorktreeSetupUpdate(phases, update, event.createdAt)
}

export function applyWorktreeSetupEventForName(
  phases: readonly SessionSetupPhaseInfo[],
  event: EventEnvelope,
  worktreeName: string | undefined
): SessionSetupPhaseInfo[] {
  const update = worktreeSetupUpdateForName(event, worktreeName)
  return applyWorktreeSetupUpdate(phases, update, event.createdAt)
}

export function applyWorktreeSetupEventForSession(
  phases: readonly SessionSetupPhaseInfo[],
  event: EventEnvelope,
  sessionId: string
): SessionSetupPhaseInfo[] {
  const update = worktreeSetupUpdateForSession(event, sessionId)
  return applyWorktreeSetupUpdate(phases, update, event.createdAt)
}

function applyWorktreeSetupUpdate(
  phases: readonly SessionSetupPhaseInfo[],
  update: WorktreeSetupUpdateType | undefined,
  createdAt: string
): SessionSetupPhaseInfo[] {
  if (update == null) return [...phases]
  const current =
    phases.find((phase) => phase.id === WORKTREE_SETUP_PHASE_ID) ?? worktreePhase(createdAt)
  const withoutWorktree = phases.filter((phase) => phase.id !== WORKTREE_SETUP_PHASE_ID)

  switch (update.state) {
    case "started":
      return [...withoutWorktree, worktreePhase(createdAt)]
    case "log": {
      if (update.line == null) return [...withoutWorktree, current]
      return [
        ...withoutWorktree,
        {
          ...current,
          logs: [
            ...current.logs,
            {
              id: current.logs.length,
              stream: update.stream ?? "stdout",
              text: update.line
            }
          ]
        }
      ]
    }
    case "completed":
      return [
        ...withoutWorktree,
        {
          ...current,
          outcome: "succeeded",
          endedAt: endedAt(current.startedAt, update.durationMs, createdAt)
        }
      ]
    case "failed":
      return [
        ...withoutWorktree,
        {
          ...current,
          outcome: "failed",
          failureMessage: update.message ?? "Worktree setup failed.",
          endedAt: endedAt(current.startedAt, update.durationMs, createdAt)
        }
      ]
  }
}

export function failRunningSetupPhases(
  phases: readonly SessionSetupPhaseInfo[],
  message: string,
  endedAt: string
): SessionSetupPhaseInfo[] {
  return phases.map((phase) =>
    phase.outcome === "running"
      ? { ...phase, outcome: "failed", failureMessage: message, endedAt }
      : phase
  )
}

function endedAt(startedAt: string, durationMs: number | undefined, fallback: string): string {
  if (durationMs == null) return fallback
  return new Date(new Date(startedAt).getTime() + durationMs).toISOString()
}
