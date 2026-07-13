import { useCallback, useEffect, useState } from "react"

const MAX_CACHED_TODO_STATES = 64
interface TodoUiState {
  isExpanded: boolean
  isCompleted: boolean
}

const todoUiStates = new Map<string, TodoUiState>()

function todoUiState(sessionId: string): TodoUiState {
  return todoUiStates.get(sessionId) ?? { isExpanded: true, isCompleted: false }
}

function rememberTodoUiState(sessionId: string, state: TodoUiState) {
  todoUiStates.delete(sessionId)
  todoUiStates.set(sessionId, state)
  if (todoUiStates.size <= MAX_CACHED_TODO_STATES) return
  const oldest = todoUiStates.keys().next().value
  if (oldest != null) todoUiStates.delete(oldest)
}

export function todoExpansionState(sessionId: string): boolean {
  return todoUiState(sessionId).isExpanded
}

export function rememberTodoExpansionState(sessionId: string, isExpanded: boolean) {
  rememberTodoUiState(sessionId, { ...todoUiState(sessionId), isExpanded })
}

// Returns true only for the transition from an unfinished checklist to a
// finished one. Remembering the completion separately from expansion lets a
// user reopen a finished checklist without the effect immediately closing it
// again, including after navigating away and back.
export function recordTodoCompletionState(sessionId: string, isCompleted: boolean): boolean {
  const previous = todoUiState(sessionId)
  const shouldCollapse = isCompleted && !previous.isCompleted
  rememberTodoUiState(sessionId, {
    isCompleted,
    isExpanded: shouldCollapse ? false : previous.isExpanded
  })
  return shouldCollapse
}

// Mirrors SessionController.isTodosExpanded on macOS: each session restores
// the checklist state it had when its route was last mounted.
export function useTodoExpansionState(sessionId: string, isCompleted: boolean | undefined) {
  const [state, setState] = useState(() => ({
    sessionId,
    isExpanded: todoExpansionState(sessionId)
  }))
  const isExpanded =
    state.sessionId === sessionId ? state.isExpanded : todoExpansionState(sessionId)

  useEffect(() => {
    // An undefined value means the session detail is still loading. Keep the
    // remembered completion edge intact so a remount does not close a
    // checklist the user already reopened.
    if (isCompleted == null) return
    if (!recordTodoCompletionState(sessionId, isCompleted)) return
    setState({ sessionId, isExpanded: false })
  }, [isCompleted, sessionId])

  const setIsExpanded = useCallback(
    (next: boolean) => {
      rememberTodoExpansionState(sessionId, next)
      setState({ sessionId, isExpanded: next })
    },
    [sessionId]
  )
  return [isExpanded, setIsExpanded] as const
}
