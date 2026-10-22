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

  const prepareHarnesses = async (harnessIds: ReadonlyArray<string>): Promise<void> => {
    if (harnessIds.length === 0) return

    const harnesses = harnessSteps()
    const prepared: Array<string> = []
    try {
      for (const harnessId of harnessIds) {
        await harnesses.prepareUpdate(harnessId)
        prepared.push(harnessId)
      }
    } catch (cause) {
      for (const harnessId of prepared) harnesses.cancelUpdate(harnessId)
      throw new HttpFailure(409, failureMessage(cause))
    }
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
    if (!joinable(request, acceptingHarnesses)) {
      throw new HttpFailure(409, "An update is already running")
    }

    const added = request.harnessIds.filter((harnessId) => !progress.harnessIds.includes(harnessId))
    await prepareHarnesses(added)
    queue = [...queue, ...added]
    if (scope.kind === "harnesses") scope = harnessChats([...scope.harnessIds, ...added])
    advance({ ...progress, harnessIds: [...progress.harnessIds, ...added] })
    void restart.begin(scope)
    return { run: state() }
  }

  const start = async (request: UpdateRunRequest): Promise<UpdateRunStarted> => {
    if (isBusy()) return join(request)

    const server =
      request.serverChannel === undefined ? undefined : await checkServer(request.serverChannel)
    return launch(request, server)
  }

  const startServerUpdate = async (channel: ServerUpdateChannel): Promise<ServerUpdateAccepted> => {
    if (isBusy() && !awaitsRestart(progress)) {
      throw new HttpFailure(409, "An update is already running")
    }

    const server = await checkServer(channel)
    await launch({ harnessIds: [], serverChannel: channel }, server)
    return server.accepted
  }

  const launch = async (
    request: UpdateRunRequest,
    server: CheckedServer | undefined
  ): Promise<UpdateRunStarted> => {
    const harnessIds = [...new Set(request.harnessIds)]
    await prepareHarnesses(harnessIds)
    const ending = endingFor(request, server)
    const withServer = server === undefined ? {} : { server: server.accepted }
    if (harnessIds.length === 0 && ending.kind !== "restartServer")
      return { run: state(), ...withServer }

    queue = [...harnessIds]
    acceptingHarnesses = true
    scope = ending.kind === "continue" ? harnessChats(harnessIds) : allChats
    advance({ state: "pausing", harnessIds, startedAt: new Date().toISOString() })
    void execute(ending).catch(async (cause: unknown) => {
      log(`Update run failed: ${failureMessage(cause)}`)
      await continueChats()
    })
    return { run: state(), ...withServer }
  }

  const execute = async (ending: Ending): Promise<void> => {
    const paused = await restart.begin(scope)
    if (paused.state !== "drained") return abandon()

    advance({ ...progress, state: "updating" })
    await updateHarnesses()
    if (ending.kind === "restartServer") return restartServer(ending.channel, ending.info)
    if (ending.kind === "holdForAppUpdate") return holdForAppUpdate()
    return continueChats()
  }

  const updateHarnesses = async (): Promise<void> => {
    for (let harnessId = queue.shift(); harnessId !== undefined; harnessId = queue.shift()) {
      await restart.begin(scope)
      restart.extendGrace()
      advance({ ...progress, currentHarnessId: harnessId })
      await harnessSteps().applyUpdate(harnessId)
    }
    acceptingHarnesses = false
    const { currentHarnessId: _finished, ...rest } = progress
    advance(rest)
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
    for (const harnessId of queue) harnessSteps().cancelUpdate(harnessId)
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
    }
  }
}

const endingFor = (request: UpdateRunRequest, server: CheckedServer | undefined): Ending => {
  if (server?.accepted.accepted === true && request.serverChannel !== undefined) {
    return { kind: "restartServer", channel: request.serverChannel, info: server.info }
  }
  if (request.holdForAppUpdate === true) return { kind: "holdForAppUpdate" }
  return { kind: "continue" }
}

const idleProgress = (): Progress => ({
  state: "idle",
  harnessIds: [],
  startedAt: new Date().toISOString()
})

const joinable = (request: UpdateRunRequest, acceptingHarnesses: boolean): boolean =>
  acceptingHarnesses && request.serverChannel === undefined && request.holdForAppUpdate !== true

const awaitsRestart = (progress: Progress): boolean =>
  progress.state === "holding" || progress.state === "restarting"
