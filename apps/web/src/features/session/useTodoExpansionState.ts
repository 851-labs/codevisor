import { useCallback, useState } from "react"

const MAX_CACHED_TODO_STATES = 64
const todoExpansionStates = new Map<string, boolean>()

export function todoExpansionState(sessionId: string): boolean {
  return todoExpansionStates.get(sessionId) ?? true
}

export function rememberTodoExpansionState(sessionId: string, isExpanded: boolean) {
  todoExpansionStates.delete(sessionId)
  todoExpansionStates.set(sessionId, isExpanded)
  if (todoExpansionStates.size <= MAX_CACHED_TODO_STATES) return
  const oldest = todoExpansionStates.keys().next().value
  if (oldest != null) todoExpansionStates.delete(oldest)
}

// Mirrors SessionController.isTodosExpanded on macOS: each session restores
// the checklist state it had when its route was last mounted.
export function useTodoExpansionState(sessionId: string) {
  const [state, setState] = useState(() => ({
    sessionId,
    isExpanded: todoExpansionState(sessionId)
  }))
  const isExpanded =
    state.sessionId === sessionId ? state.isExpanded : todoExpansionState(sessionId)
  const setIsExpanded = useCallback(
    (next: boolean) => {
      rememberTodoExpansionState(sessionId, next)
      setState({ sessionId, isExpanded: next })
    },
    [sessionId]
  )
  return [isExpanded, setIsExpanded] as const
}
