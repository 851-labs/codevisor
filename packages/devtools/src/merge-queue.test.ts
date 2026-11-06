import { describe, expect, it } from "vitest"

import {
  nextWaitStep,
  type PullRequestFields,
  startOfWait,
  type WaitProgress
} from "./merge-queue.ts"

const queued: PullRequestFields = {
  state: "OPEN",
  autoMergeRequest: null,
  mergeQueueEntry: { state: "QUEUED" }
}
const outOfQueue: PullRequestFields = {
  state: "OPEN",
  autoMergeRequest: null,
  mergeQueueEntry: null
}
const merged: PullRequestFields = { state: "MERGED", autoMergeRequest: null, mergeQueueEntry: null }

const verdicts = (polls: Array<PullRequestFields | undefined>) => {
  let progress: WaitProgress = startOfWait
  return polls.map((fields) => {
    const step = nextWaitStep(progress, fields)
    progress = step.progress
    return step.verdict
  })
}

describe("nextWaitStep", () => {
  it("keeps waiting while queued and reports a merge", () => {
    expect(verdicts([queued, queued, merged])).toEqual(["waiting", "waiting", "landed"])
  })

  it("needs two polls out of the queue before reporting it left, so a merge in flight isn't one", () => {
    expect(verdicts([outOfQueue, merged])).toEqual(["waiting", "landed"])
    expect(verdicts([outOfQueue, outOfQueue])).toEqual(["waiting", "left-queue"])
  })

  it("rides out a few unreachable polls but gives up after many", () => {
    expect(verdicts([undefined, undefined, queued])).toEqual(["waiting", "waiting", "waiting"])
    expect(verdicts(Array.from({ length: 16 }, () => undefined)).at(-1)).toBe("lost-contact")
  })
})
