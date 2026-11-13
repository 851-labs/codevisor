import {
  Bot,
  decode,
  FLEET_BOT_IMPORT_PATH,
  type BotImportAction,
  type BotImportMessage,
  type BotImportProject,
  type BotImportSpec,
  type BotMessage,
  type ForkBotRequest,
  type MachineCallOrigin
} from "@codevisor/api"
import { CodeExecutionToolError } from "@codevisor/automation"

import { PeerAnswerError, type MachineLink } from "../infra/machine-link.js"
import { getProjectOrFail, HttpFailure, run } from "../server-context.js"
import { forkHandoffText } from "./bot-fork-handoff.js"
import { forkableBot, forkSpec, movedAgents, type BotFork } from "./bot-fork-parts.js"
import { sendImportFiles } from "./bot-fork-remote-files.js"
import { botNotes } from "./bot-instructions.js"

export interface ForkTarget {
  readonly id: string
  readonly name: string
}

export interface RemoteFork {
  readonly sourceId: string
  readonly payload: ForkBotRequest
  readonly target: ForkTarget
}

export type ImportSender = (action: BotImportAction) => Promise<unknown>

export const forkTargetMachine = async (
  fork: BotFork,
  toMachine: string | undefined
): Promise<ForkTarget | undefined> => {
  if (toMachine === undefined || toMachine === fork.config.id) return undefined

  const found = (await machineLink(fork).list()).find((machine) => names(machine, toMachine))
  if (found === undefined) throw new HttpFailure(404, `No machine "${toMachine}" on this account`)
  if (found.isCurrent) return undefined
  return { id: found.id, name: found.name }
}

export const forkBotToMachine = async (fork: BotFork, remote: RemoteFork): Promise<Bot> => {
  const source = await forkableBot(fork.services, remote.sourceId)
  const origin = await callOrigin(fork)
  const send = importSender(machineLink(fork), remote.target, origin)
  const messages = await allMessages(fork, source)
  const spec = await importSpec(fork, { source, remote, messages })
  await sendImportFiles(fork.services, send, messages)
  const forked = decode(Bot)(await send({ action: "create", bot: spec }))

  const agents = await movedAgents(fork, remote.payload, {
    fromAgentId: source.sessionId,
    toAgentId: forked.sessionId,
    toMachineId: remote.target.id
  })
  const handoff = { source, targetHarnessId: forked.harnessId, agents }
  const text = await forkHandoffText(fork.services, fork.routeState, {
    ...handoff,
    agentsMachineName: origin.machineName
  })
  await send({ action: "handoff", botId: forked.id, text })
  return forked
}

const machineLink = (fork: BotFork): MachineLink => {
  const machines = fork.services.machines
  if (machines === undefined)
    throw new HttpFailure(501, "This machine can't reach your other machines")
  return machines
}

const names = (machine: { readonly id: string; readonly name: string }, wanted: string): boolean =>
  machine.id === wanted || machine.name.toLowerCase() === wanted.toLowerCase()

const callOrigin = async (fork: BotFork): Promise<MachineCallOrigin> => {
  const self = (await machineLink(fork).list()).find((machine) => machine.isCurrent)
  return { machineId: fork.config.id, machineName: self?.name ?? fork.config.name }
}

const importSender =
  (machines: MachineLink, target: ForkTarget, origin: MachineCallOrigin): ImportSender =>
  (action) =>
    machines.invoke(target.id, FLEET_BOT_IMPORT_PATH, action, origin).catch(rethrowAsHttp)

const rethrowAsHttp = (cause: unknown): never => {
  if (cause instanceof PeerAnswerError)
    throw new HttpFailure(cause.status, cause.message, cause.code)
  if (cause instanceof CodeExecutionToolError) throw new HttpFailure(503, cause.message, cause.code)
  throw cause
}

const pageSize = 500

const allMessages = async (fork: BotFork, source: Bot): Promise<ReadonlyArray<BotMessage>> => {
  const pages: Array<ReadonlyArray<BotMessage>> = []
  let before: number | undefined
  for (;;) {
    const page = await run(fork.services.db.listBotMessages(source.sessionId, before, pageSize))
    pages.unshift(page.messages)
    before = page.messages[0]?.sequence
    if (!page.hasMore || before === undefined) return pages.flat()
  }
}

interface ImportParts {
  readonly source: Bot
  readonly remote: RemoteFork
  readonly messages: ReadonlyArray<BotMessage>
}

const importSpec = async (fork: BotFork, parts: ImportParts): Promise<BotImportSpec> => {
  const spec = forkSpec(parts.source, parts.remote.payload)
  const notes = botNotes(parts.source)
  return {
    id: spec.id,
    name: spec.name,
    symbolName: spec.symbolName,
    mascot: spec.mascot ?? parts.source.mascot,
    harnessId: spec.harnessId,
    ...(spec.configSelections === undefined ? {} : { configSelections: spec.configSelections }),
    projects: await importProjects(fork, spec.projectIds, parts.remote.target),
    ...(notes === undefined ? {} : { notes }),
    messages: parts.messages.map(importMessage)
  }
}

const importProjects = async (
  fork: BotFork,
  projectIds: ReadonlyArray<string>,
  target: ForkTarget
): Promise<ReadonlyArray<BotImportProject>> => {
  const projects: Array<BotImportProject> = []
  for (const projectId of projectIds) {
    const project = await getProjectOrFail(fork.services.db, projectId)
    if (project.repoUrl === undefined) {
      throw new HttpFailure(
        422,
        `${project.name} has no git remote, so it can't be cloned onto ${target.name}`,
        "no_remote"
      )
    }
    projects.push({ name: project.name, repoUrl: project.repoUrl })
  }
  return projects
}

const importMessage = (message: BotMessage): BotImportMessage => ({
  sender: message.sender,
  text: message.text,
  ...(message.attachments === undefined ? {} : { attachments: message.attachments }),
  createdAt: message.createdAt
})
