export interface PullRequestFields {
  readonly state: string
  readonly autoMergeRequest: unknown
  readonly mergeQueueEntry: unknown
}

export interface WaitProgress {
  readonly unreachablePolls: number
  readonly outOfQueuePolls: number
}

export type WaitVerdict = "landed" | "left-queue" | "lost-contact" | "waiting"

export interface WaitStep {
  readonly verdict: WaitVerdict
  readonly progress: WaitProgress
}

export const startOfWait: WaitProgress = { unreachablePolls: 0, outOfQueuePolls: 0 }

const unreachablePollsAllowed = 15
const outOfQueuePollsToConfirm = 2

export function nextWaitStep(
  progress: WaitProgress,
  fields: PullRequestFields | undefined
): WaitStep {
  const next = {
    unreachablePolls: fields === undefined ? progress.unreachablePolls + 1 : 0,
    outOfQueuePolls: fields !== undefined && leftQueue(fields) ? progress.outOfQueuePolls + 1 : 0
  }
  return { verdict: verdictFor(next, fields), progress: next }
}

function verdictFor(progress: WaitProgress, fields: PullRequestFields | undefined): WaitVerdict {
  if (progress.unreachablePolls > unreachablePollsAllowed) return "lost-contact"
  if (fields?.state === "MERGED") return "landed"

  return progress.outOfQueuePolls >= outOfQueuePollsToConfirm ? "left-queue" : "waiting"
}

function leftQueue(fields: PullRequestFields): boolean {
  return (
    fields.state === "OPEN" && fields.autoMergeRequest === null && fields.mergeQueueEntry === null
  )
}
