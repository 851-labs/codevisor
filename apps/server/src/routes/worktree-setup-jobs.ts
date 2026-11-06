import type { StartWorktreeSetupRequest, Worktree, WorktreeSetupStatus } from "@codevisor/api"

import {
  failureMessage,
  HttpFailure,
  run,
  swallowError,
  type CodevisorServerServices
} from "../server-context.js"
import {
  addPlannedWorktree,
  planProjectWorktree,
  type WorktreeServices
} from "./project-worktree-create.js"

export const startWorktreeSetup = (
  worktreeServices: WorktreeServices,
  projectId: string,
  payload: StartWorktreeSetupRequest
): Promise<WorktreeSetupStatus> => {
  const jobs = jobsFor(worktreeServices.services)
  const key = jobKey(payload.id)
  const current = jobs.active.get(key)
  if (current !== undefined) return current

  const started = beginSetup(worktreeServices, jobs, projectId, payload)
  jobs.active.set(key, started)
  void started.then(
    (status) => forgetUnlessRunning(jobs, key, started, status),
    () => forget(jobs, key, started)
  )
  return started
}

export const worktreeSetupStatus = async (
  services: CodevisorServerServices,
  projectId: string,
  worktreeId: string
): Promise<WorktreeSetupStatus> => {
  const jobs = jobsFor(services)
  const key = jobKey(worktreeId)
  if (jobs.active.has(key)) return running(worktreeId)

  const failure = jobs.failures.get(key)
  if (failure !== undefined) return failed(worktreeId, failure)

  const worktree = await findWorktree(services, projectId, worktreeId)
  if (worktree === undefined) throw unknownSetup(worktreeId)
  return completed(worktree)
}

export const worktreeSetupsIdle = async (services: CodevisorServerServices): Promise<void> => {
  const jobs = jobsFor(services)
  while (jobs.work.size > 0) await Promise.all(jobs.work)
}

interface WorktreeSetupJobs {
  readonly active: Map<string, Promise<WorktreeSetupStatus>>
  readonly failures: Map<string, string>
  readonly work: Set<Promise<void>>
}

const rememberedFailureLimit = 100

const registries = new WeakMap<CodevisorServerServices, WorktreeSetupJobs>()

const jobsFor = (services: CodevisorServerServices): WorktreeSetupJobs => {
  let jobs = registries.get(services)
  if (jobs === undefined) {
    jobs = { active: new Map(), failures: new Map(), work: new Set() }
    registries.set(services, jobs)
  }
  return jobs
}

const jobKey = (worktreeId: string): string => worktreeId.toLowerCase()

const beginSetup = async (
  worktreeServices: WorktreeServices,
  jobs: WorktreeSetupJobs,
  projectId: string,
  payload: StartWorktreeSetupRequest
): Promise<WorktreeSetupStatus> => {
  const existing = await findWorktree(worktreeServices.services, projectId, payload.id)
  if (existing !== undefined) return completed(existing)

  const plan = await planProjectWorktree(worktreeServices, projectId, payload)
  jobs.failures.delete(jobKey(payload.id))
  track(
    jobs,
    runSetup(jobs, jobKey(payload.id), () => addPlannedWorktree(plan))
  )
  return running(payload.id)
}

const runSetup = async (
  jobs: WorktreeSetupJobs,
  key: string,
  addWorktree: () => Promise<Worktree>
): Promise<void> => {
  try {
    await addWorktree()
  } catch (cause) {
    rememberFailure(jobs, key, failureMessage(cause))
  } finally {
    jobs.active.delete(key)
  }
}

const track = (jobs: WorktreeSetupJobs, work: Promise<void>): void => {
  const settled = work.catch(swallowError)
  jobs.work.add(settled)
  void settled.then(() => jobs.work.delete(settled))
}

const rememberFailure = (jobs: WorktreeSetupJobs, key: string, message: string): void => {
  jobs.failures.delete(key)
  jobs.failures.set(key, message)
  const oldest = jobs.failures.keys().next().value
  if (jobs.failures.size > rememberedFailureLimit && oldest !== undefined) {
    jobs.failures.delete(oldest)
  }
}

const forgetUnlessRunning = (
  jobs: WorktreeSetupJobs,
  key: string,
  started: Promise<WorktreeSetupStatus>,
  status: WorktreeSetupStatus
): void => {
  if (status.state !== "running") forget(jobs, key, started)
}

const forget = (
  jobs: WorktreeSetupJobs,
  key: string,
  started: Promise<WorktreeSetupStatus>
): void => {
  if (jobs.active.get(key) === started) jobs.active.delete(key)
}

const findWorktree = async (
  services: CodevisorServerServices,
  projectId: string,
  worktreeId: string
): Promise<Worktree | undefined> =>
  (await run(services.db.listWorktrees(projectId))).find(
    (worktree) => jobKey(worktree.id) === jobKey(worktreeId)
  )

const running = (worktreeId: string): WorktreeSetupStatus => ({ worktreeId, state: "running" })

const completed = (worktree: Worktree): WorktreeSetupStatus => ({
  worktreeId: worktree.id,
  state: "completed",
  worktree
})

const failed = (worktreeId: string, message: string): WorktreeSetupStatus => ({
  worktreeId,
  state: "failed",
  message
})

const unknownSetup = (worktreeId: string): HttpFailure =>
  new HttpFailure(404, `No worktree setup found for ${worktreeId}`)
