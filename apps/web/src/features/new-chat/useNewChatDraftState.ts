import { useSyncExternalStore } from "react"

import type { SessionSetupPhaseInfo } from "../../lib/session-setup"

const STORAGE_KEY = "codevisor-composer-defaults"

export interface NewChatDraftState {
  selectedProjectId?: string
  selectedHarnessId?: string
  runInWorktree: boolean
  pendingModeId?: string
  configByHarness: Record<string, Record<string, string>>
  isGoalComposerArmed: boolean
  error?: string
  setupWorktreeId?: string
  setupPhases: SessionSetupPhaseInfo[]
}

export interface RememberedComposerDefaults {
  selectedHarnessId?: string
  runInWorktree: boolean
  configByHarness: Record<string, Record<string, string>>
}

function readRememberedDefaults(): RememberedComposerDefaults {
  if (typeof window === "undefined") {
    return { runInWorktree: false, configByHarness: {} }
  }
  try {
    const value = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? "null") as unknown
    if (value == null || typeof value !== "object") {
      return { runInWorktree: false, configByHarness: {} }
    }
    const record = value as Record<string, unknown>
    return {
      selectedHarnessId:
        typeof record["selectedHarnessId"] === "string" ? record["selectedHarnessId"] : undefined,
      runInWorktree: record["runInWorktree"] === true,
      configByHarness:
        record["configByHarness"] != null && typeof record["configByHarness"] === "object"
          ? (record["configByHarness"] as Record<string, Record<string, string>>)
          : {}
    }
  } catch {
    return { runInWorktree: false, configByHarness: {} }
  }
}

export function initialNewChatDraftState(
  defaults: RememberedComposerDefaults = readRememberedDefaults()
): NewChatDraftState {
  return {
    selectedHarnessId: defaults.selectedHarnessId,
    runInWorktree: defaults.runInWorktree,
    configByHarness: defaults.configByHarness,
    isGoalComposerArmed: false,
    setupPhases: []
  }
}

export function updateNewChatHarnessConfig(
  state: NewChatDraftState,
  harnessId: string,
  configId: string,
  value: string
): NewChatDraftState {
  return {
    ...state,
    configByHarness: {
      ...state.configByHarness,
      [harnessId]: { ...state.configByHarness[harnessId], [configId]: value }
    }
  }
}

export function moveNewChatDraftToProject(
  state: NewChatDraftState,
  projectId: string,
  supportsWorktrees: boolean
): NewChatDraftState {
  if (state.selectedProjectId === projectId) {
    return {
      ...state,
      runInWorktree: supportsWorktrees ? state.runInWorktree : false
    }
  }
  return {
    ...state,
    selectedProjectId: projectId,
    runInWorktree: supportsWorktrees ? state.runInWorktree : false,
    pendingModeId: undefined,
    error: undefined,
    setupWorktreeId: undefined,
    setupPhases: []
  }
}

export function newChatDraftAfterSessionCreation(
  _state: NewChatDraftState,
  defaults: {
    selectedHarnessId: string
    runInWorktree: boolean
    config: Record<string, string>
  },
  remembered: RememberedComposerDefaults = { runInWorktree: false, configByHarness: {} }
): NewChatDraftState {
  return initialNewChatDraftState({
    selectedHarnessId: defaults.selectedHarnessId,
    runInWorktree: defaults.runInWorktree,
    configByHarness: {
      ...remembered.configByHarness,
      [defaults.selectedHarnessId]: defaults.config
    }
  })
}

let rememberedDefaults = readRememberedDefaults()
let draftState = initialNewChatDraftState(rememberedDefaults)
const listeners = new Set<() => void>()

export function updateNewChatDraftState(
  update: NewChatDraftState | ((current: NewChatDraftState) => NewChatDraftState)
) {
  draftState = typeof update === "function" ? update(draftState) : update
  for (const listener of listeners) listener()
}

export function rememberNewChatSessionDefaults(defaults: {
  selectedHarnessId: string
  runInWorktree: boolean
  config: Record<string, string>
}) {
  draftState = newChatDraftAfterSessionCreation(draftState, defaults, rememberedDefaults)
  rememberedDefaults = {
    selectedHarnessId: draftState.selectedHarnessId,
    runInWorktree: draftState.runInWorktree,
    configByHarness: draftState.configByHarness
  }
  if (typeof window !== "undefined") {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(rememberedDefaults))
    } catch {
      // In-memory draft retention still works when storage is unavailable.
    }
  }
  for (const listener of listeners) listener()
}

export function useNewChatDraftState(): NewChatDraftState {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    () => draftState,
    () => draftState
  )
}
