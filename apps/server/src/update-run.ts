import type {
  ServerUpdateAccepted,
  UpdateInfo,
  UpdateRunRequest,
  UpdateRunStarted,
  UpdateRunState
} from "@codevisor/api"
import type { HarnessLifecycleManager } from "@codevisor/harness-manager"
import type { ServerUpdateChannel } from "@codevisor/updater"

import { allChats, harnessChats, type PauseScope } from "./pause-scope.js"
import type { RestartCoordinator } from "./restart-drain.js"
import { failureMessage, HttpFailure } from "./server-context.js"

export type HarnessUpdateSteps = Pick<
  HarnessLifecycleManager,
  "applyUpdate" | "cancelUpdate" | "prepareUpdate"
>

export interface ServerUpdateSteps {
  readonly check: (channel: ServerUpdateChannel) => Promise<UpdateInfo>
  readonly apply: (channel: ServerUpdateChannel, info: UpdateInfo) => Promise<void>
}

export interface UpdateRun {
  readonly state: () => UpdateRunState
  readonly start: (request: UpdateRunRequest) => Promise<UpdateRunStarted>
  readonly startServerUpdate: (channel: ServerUpdateChannel) => Promise<ServerUpdateAccepted>
  readonly cancel: () => Promise<UpdateRunState>
  readonly noteChatsChanged: () => void
  readonly restartsServer: () => boolean
}

export interface UpdateRunDeps {
  readonly restart: RestartCoordinator
  readonly harnesses: HarnessUpdateSteps | undefined
  readonly server: ServerUpdateSteps | undefined
  readonly pausedSessionIds: () => ReadonlyArray<string>
  readonly onChange: () => void
  readonly log?: ((line: string) => void) | undefined
}

type Ending =
  | { readonly kind: "continue" }
  | { readonly kind: "holdForAppUpdate" }
  | {
      readonly kind: "restartServer"
      readonly channel: ServerUpdateChannel
      readonly info: UpdateInfo
    }

interface CheckedServer {
  readonly accepted: ServerUpdateAccepted
  readonly info: UpdateInfo
}

interface PreparedHarnesses {
  readonly prepared: ReadonlyArray<string>
  readonly refusal: HttpFailure | undefined
}

interface Progress {
  readonly state: UpdateRunState["state"]
  readonly harnessIds: ReadonlyArray<string>
  readonly currentHarnessId?: string
  readonly startedAt: string
}

export const makeUpdateRun = (deps: UpdateRunDeps): UpdateRun => {
  const { restart } = deps
  const log = deps.log ?? ((line: string) => console.log(line))

  let progress: Progress = idleProgress()
  let queue: Array<string> = []
  let scope: PauseScope = allChats
  let ending: Ending = continueEnding
  let acceptingHarnesses = false

  const state = (): UpdateRunState => ({
    ...progress,
    pausing: progress.state === "pausing" ? restart.state().remaining : 0
  })

  const advance = (next: Progress): void => {
    progress = next
    deps.onChange()
  }

  const isBusy = (): boolean => progress.state !== "idle" && progress.state !== "continuing"

  const harnessSteps = (): HarnessUpdateSteps => {
    if (deps.harnesses === undefined) throw new HttpFailure(501, "Harness update unavailable")
    return deps.harnesses
  }

  const serverSteps = (): ServerUpdateSteps => {
    if (deps.server === undefined) {
      throw new HttpFailure(409, "This server does not support remote updates")
    }
    return deps.server
  }

  const prepareHarnesses = async (
    harnessIds: ReadonlyArray<string>
  ): Promise<PreparedHarnesses> => {
    const prepared: Array<string> = []
    let refusal: HttpFailure | undefined
    for (const harnessId of harnessIds) {
      try {
        await harnessSteps().prepareUpdate(harnessId)
        prepared.push(harnessId)
      } catch (cause) {
        refusal ??= refusalFrom(cause)
        log(`Skipping the ${harnessId} update: ${failureMessage(cause)}`)
      }
    }
    return { prepared, refusal }
  }

  const unprepare = (harnessIds: ReadonlyArray<string>): void => {
    for (const harnessId of harnessIds) harnessSteps().cancelUpdate(harnessId)
  }

  const checkServer = async (channel: ServerUpdateChannel): Promise<CheckedServer> => {
    const info = await serverSteps().check(channel)
    const draining = restart.state().remaining > 0
    if (!info.updateAvailable) {
      return { accepted: { accepted: false, targetVersion: info.currentVersion }, info }
    }
    return {
      accepted: {
        accepted: true,
        targetVersion: info.latestVersion,
        ...(info.latestBuildNumber === undefined
          ? {}
          : { targetBuildNumber: info.latestBuildNumber }),
        draining
      },
      info
    }
  }

  const join = async (request: UpdateRunRequest): Promise<UpdateRunStarted> => {
    if (!acceptingHarnesses) throw new HttpFailure(409, "An update is already running")

    const added = request.harnessIds.filter((harnessId) => !progress.harnessIds.includes(harnessId))
    const { prepared, refusal } = await prepareHarnesses(added)
    const server = await serverForJoin(request)
    if (!acceptingHarnesses) {
      unprepare(prepared)
      throw new HttpFailure(409, "An update is already running")
    }
    if (nothingToJoin(prepared, refusal, request, server)) throw refusal

    adoptEnding(request, server)
    queue = [...queue, ...prepared]
    if (scope.kind === "harnesses") scope = harnessChats([...scope.harnessIds, ...prepared])
    advance({ ...progress, harnessIds: [...progress.harnessIds, ...prepared] })
    void restart.begin(scope)
    return { run: state(), ...(server === undefined ? {} : { server: server.accepted }) }
  }

  const serverForJoin = (request: UpdateRunRequest): Promise<CheckedServer> | undefined => {
    if (request.serverChannel === undefined) return undefined
    return checkServer(request.serverChannel)
  }

  const adoptEnding = (request: UpdateRunRequest, server: CheckedServer | undefined): void => {
    const requested = endingFor(request, server)
    if (requested.kind === "restartServer" || ending.kind === "continue") ending = requested
  }

  const start = async (request: UpdateRunRequest): Promise<UpdateRunStarted> => {
    if (isBusy()) return join(request)

    if (request.serverChannel === undefined) return launch(request, undefined)
    return launch(request, await checkServer(request.serverChannel))
  }

  const startServerUpdate = async (channel: ServerUpdateChannel): Promise<ServerUpdateAccepted> => {
    if (acceptingHarnesses) return joinServerUpdate(channel)
    if (isBusy() && !awaitsRestart(progress)) {
      throw new HttpFailure(409, "An update is already running")
    }

    const server = await checkServer(channel)
    await launch({ harnessIds: [], serverChannel: channel }, server)
    return server.accepted
  }

  const joinServerUpdate = async (channel: ServerUpdateChannel): Promise<ServerUpdateAccepted> => {
    const { server } = await join({ harnessIds: [], serverChannel: channel })
    if (server === undefined) throw new HttpFailure(409, "An update is already running")
    return server
  }

  const launch = async (
    request: UpdateRunRequest,
    server: CheckedServer | undefined
  ): Promise<UpdateRunStarted> => {
    const requested = [...new Set(request.harnessIds)]
    const { prepared, refusal } = await prepareHarnesses(requested)
    const next = endingFor(request, server)
    const withServer = server === undefined ? {} : { server: server.accepted }
    if (prepared.length === 0 && next.kind === "continue" && refusal !== undefined) throw refusal
    if (prepared.length === 0 && next.kind !== "restartServer")
      return { run: state(), ...withServer }

    queue = [...prepared]
    ending = next
    acceptingHarnesses = true
    scope = prepared.length === 0 ? allChats : harnessChats(prepared)
    advance({ state: "pausing", harnessIds: prepared, startedAt: new Date().toISOString() })
    void execute().catch(async (cause: unknown) => {
      log(`Update run failed: ${failureMessage(cause)}`)
      await continueChats()
    })
    return { run: state(), ...withServer }
  }

  const execute = async (): Promise<void> => {
    const paused = await restart.begin(scope)
    if (paused.state !== "drained") return abandon()

    advance({ ...progress, state: "updating" })
    await updateHarnesses()
    await finish()
  }

  const updateHarnesses = async (): Promise<void> => {
    for (let harnessId = queue.shift(); harnessId !== undefined; harnessId = queue.shift()) {
      await restart.begin(scope)
      restart.extendGrace()
      advance({ ...progress, currentHarnessId: harnessId })
      await applyHarnessUpdate(harnessId)
    }
    acceptingHarnesses = false
    const { currentHarnessId: _finished, ...rest } = progress
    advance(rest)
  }

  const applyHarnessUpdate = async (harnessId: string): Promise<void> => {
    try {
      await harnessSteps().applyUpdate(harnessId)
    } catch (cause) {
      log(`The ${harnessId} update failed: ${failureMessage(cause)}`)
    }
  }

  const finish = async (): Promise<void> => {
    const final = ending
    if (final.kind === "continue") return continueChats()
    if (!(await pauseAllChats())) return abandon()

    if (final.kind === "restartServer") return restartServer(final.channel, final.info)
    return holdForAppUpdate()
  }

  const pauseAllChats = async (): Promise<boolean> => {
    if (scope.kind === "all") return true

    scope = allChats
    advance({ ...progress, state: "pausing" })
    const paused = await restart.begin(allChats)
    return paused.state === "drained"
  }

  const restartServer = async (channel: ServerUpdateChannel, info: UpdateInfo): Promise<void> => {
    advance({ ...progress, state: "restarting" })
    try {
      await serverSteps().apply(channel, info)
    } catch (cause) {
      log(`Server update failed: ${failureMessage(cause)}`)
      await continueChats()
    }
  }

  const holdForAppUpdate = (): void => {
    restart.extendGrace()
    advance({ ...progress, state: "holding" })
  }

  const continueChats = async (): Promise<void> => {
    advance({ ...progress, state: "continuing" })
    await restart.cancel()
    settleContinuing()
  }

  const abandon = (): void => {
    unprepare(queue)
    queue = []
    acceptingHarnesses = false
    advance(idleProgress())
  }

  const settleContinuing = (): void => {
    if (progress.state !== "continuing") return
    if (deps.pausedSessionIds().length > 0) return

    advance(idleProgress())
  }

  return {
    state,
    start,
    startServerUpdate,
    cancel: async () => {
      if (progress.state !== "pausing") {
        throw new HttpFailure(409, "The update can only be cancelled while chats are pausing")
      }

      await restart.cancel()
      return state()
    },
    noteChatsChanged: () => {
      if (awaitsRestart(progress) && !restart.isActive()) {
        advance({ ...progress, state: "continuing" })
      }
      if (progress.state === "pausing") deps.onChange()
      settleContinuing()
    },
    restartsServer: () => isBusy() && ending.kind === "restartServer"
  }
}

const continueEnding: Ending = { kind: "continue" }

const endingFor = (request: UpdateRunRequest, server: CheckedServer | undefined): Ending => {
  if (server?.accepted.accepted === true && request.serverChannel !== undefined) {
    return { kind: "restartServer", channel: request.serverChannel, info: server.info }
  }
  if (request.holdForAppUpdate === true) return { kind: "holdForAppUpdate" }
  return continueEnding
}

const refusalFrom = (cause: unknown): HttpFailure =>
  cause instanceof HttpFailure ? cause : new HttpFailure(409, failureMessage(cause))

const nothingToJoin = (
  prepared: ReadonlyArray<string>,
  refusal: HttpFailure | undefined,
  request: UpdateRunRequest,
  server: CheckedServer | undefined
): refusal is HttpFailure =>
  prepared.length === 0 &&
  refusal !== undefined &&
  server === undefined &&
  request.holdForAppUpdate !== true

const idleProgress = (): Progress => ({
  state: "idle",
  harnessIds: [],
  startedAt: new Date().toISOString()
})

const awaitsRestart = (progress: Progress): boolean =>
  progress.state === "holding" || progress.state === "restarting"
