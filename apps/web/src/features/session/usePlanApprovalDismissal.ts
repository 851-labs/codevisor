import { useCallback, useState } from "react"

const MAX_CACHED_PLAN_APPROVALS = 64
const dismissedPlanApprovals = new Map<string, string>()

export function dismissedPlanApprovalKey(sessionId: string): string | undefined {
  return dismissedPlanApprovals.get(sessionId)
}

export function rememberDismissedPlanApproval(sessionId: string, key: string | undefined) {
  dismissedPlanApprovals.delete(sessionId)
  if (key == null) return
  dismissedPlanApprovals.set(sessionId, key)
  if (dismissedPlanApprovals.size <= MAX_CACHED_PLAN_APPROVALS) return
  const oldest = dismissedPlanApprovals.keys().next().value
  if (oldest != null) dismissedPlanApprovals.delete(oldest)
}

export function usePlanApprovalDismissal(sessionId: string) {
  const [state, setState] = useState(() => ({
    sessionId,
    key: dismissedPlanApprovalKey(sessionId)
  }))
  const key = state.sessionId === sessionId ? state.key : dismissedPlanApprovalKey(sessionId)
  const setKey = useCallback(
    (next: string | undefined) => {
      rememberDismissedPlanApproval(sessionId, next)
      setState({ sessionId, key: next })
    },
    [sessionId]
  )
  return [key, setKey] as const
}
