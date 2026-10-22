import { attachTarget, type BrowserRuntime } from "./browser-cdp-engine.js"
import { recordOrUndefined } from "./unknown-values.js"

export type BrowserPreviewState = "inactive" | "active" | "idle" | "stopped"

export interface BrowserPreviewStatus {
  readonly state: BrowserPreviewState
  readonly title: string
  readonly url: string
}

export interface BrowserPreviewViewer {
  readonly status: (status: BrowserPreviewStatus) => void
  readonly frame: (data: string) => void
}

export interface BrowserPreviewSubscription {
  readonly watch: (dimension: number) => void
  readonly unwatch: () => void
  readonly close: () => void
}

interface BrowserPreviewTimers<Timer> {
  readonly setTimer: (callback: () => void, ms: number) => Timer
  readonly clearTimer: (timer: Timer) => void
}

export type BrowserPreviewsOptions<Timer> = { readonly now?: () => number } & (
  | BrowserPreviewTimers<Timer>
  | { readonly setTimer?: undefined; readonly clearTimer?: undefined }
)

const nodeTimers: BrowserPreviewTimers<NodeJS.Timeout> = {
  setTimer: (callback, ms) => setTimeout(callback, ms).unref(),
  clearTimer: (timer) => clearTimeout(timer)
}

const IDLE_MS = 60_000
const MIN_DIMENSION = 320
const MAX_DIMENSION = 1920
const DEFAULT_DIMENSION = 1280
const INFO_REFRESH_MS = 1_000
export const BROWSER_PREVIEW_SWITCH_HOLD_MS = 600

interface Stream {
  readonly runtime: BrowserRuntime
  readonly targetId: string
  readonly cdpSession: string
  readonly dimension: number
  readonly dispose: () => void
}

interface Session<Timer = unknown> {
  status: BrowserPreviewStatus
  runtime: BrowserRuntime | undefined
  targetId: string | undefined
  readonly viewers: Map<BrowserPreviewViewer, { watching: boolean; dimension: number }>
  stream: Stream | undefined
  pending: Promise<void>
  idleTimer: Timer | undefined
  infoRefreshedAt: number
  infoTimer: Timer | undefined
  infoWatch: { readonly runtime: BrowserRuntime; readonly dispose: () => void } | undefined
  shownAt: number
  switchTimer: Timer | undefined
}

const clampDimension = (value: number): number =>
  Number.isFinite(value)
    ? Math.min(MAX_DIMENSION, Math.max(MIN_DIMENSION, Math.round(value)))
    : DEFAULT_DIMENSION

const publish = (entry: Session, next: Partial<BrowserPreviewStatus>): void => {
  const status = { ...entry.status, ...next }
  if (
    status.state === entry.status.state &&
    status.title === entry.status.title &&
    status.url === entry.status.url
  )
    return
  entry.status = status
  for (const viewer of entry.viewers.keys()) viewer.status(status)
}

const desiredDimension = (entry: Session): number | undefined => {
  const watching = [...entry.viewers.values()].filter((viewer) => viewer.watching)
  if (watching.length === 0 || entry.status.state !== "active") return undefined
  return Math.max(...watching.map((viewer) => viewer.dimension))
}

const stopStream = async (entry: Session): Promise<void> => {
  const stream = entry.stream
  if (stream === undefined) return
  entry.stream = undefined
  stream.dispose()
  await stream.runtime.connection
    .send("Page.stopScreencast", {}, stream.cdpSession)
    .catch(() => undefined)
}

const createBrowserPreviews = <Timer>(
  { setTimer, clearTimer }: BrowserPreviewTimers<Timer>,
  now: () => number
) => {
  const sessions = new Map<string, Session<Timer>>()

  const session = (sessionId: string): Session<Timer> => {
    const existing = sessions.get(sessionId)
    if (existing !== undefined) return existing
    const created: Session<Timer> = {
      status: { state: "inactive", title: "", url: "" },
      runtime: undefined,
      targetId: undefined,
      stream: undefined,
      idleTimer: undefined,
      viewers: new Map(),
      pending: Promise.resolve(),
      infoRefreshedAt: Number.NEGATIVE_INFINITY,
      infoTimer: undefined,
      infoWatch: undefined,
      shownAt: Number.NEGATIVE_INFINITY,
      switchTimer: undefined
    }
    sessions.set(sessionId, created)
    return created
  }

  const watchInfo = (entry: Session<Timer>, runtime: BrowserRuntime | undefined): void => {
    if (entry.infoWatch?.runtime === runtime) return
    entry.infoWatch?.dispose()
    if (runtime === undefined) {
      entry.infoWatch = undefined
      return
    }
    entry.infoWatch = {
      runtime,
      dispose: runtime.connection.on("Target.targetInfoChanged", (params) => {
        const info = recordOrUndefined(params.targetInfo)
        if (info === undefined || info.targetId !== entry.targetId) return
        publish(entry, {
          title: typeof info.title === "string" ? info.title : "",
          url: typeof info.url === "string" ? info.url : ""
        })
      })
    }
  }

  const refreshInfo = (entry: Session<Timer>): void => {
    if (entry.infoTimer !== undefined) return
    const wait = entry.infoRefreshedAt + INFO_REFRESH_MS - now()
    if (wait > 0) {
      entry.infoTimer = setTimer(() => {
        entry.infoTimer = undefined
        refreshInfo(entry)
      }, wait)
      return
    }
    const { runtime, targetId } = entry
    if (runtime === undefined || targetId === undefined) return
    entry.infoRefreshedAt = now()
    void runtime.connection
      .send<{
        targetInfos: ReadonlyArray<{ targetId: string; title?: string; url?: string }>
      }>("Target.getTargets")
      .then(({ targetInfos }) => {
        const info = targetInfos.find((target) => target.targetId === targetId)
        if (info === undefined || entry.targetId !== targetId) return
        publish(entry, { title: info.title ?? "", url: info.url ?? "" })
      })
      .catch(() => undefined)
  }

  const stopInfo = (entry: Session<Timer>): void => {
    if (entry.infoTimer !== undefined) clearTimer(entry.infoTimer)
    entry.infoTimer = undefined
    watchInfo(entry, undefined)
  }

  const cancelSwitch = (entry: Session<Timer>): void => {
    if (entry.switchTimer !== undefined) clearTimer(entry.switchTimer)
    entry.switchTimer = undefined
  }

  const follow = (entry: Session<Timer>, runtime: BrowserRuntime, targetId: string): void => {
    cancelSwitch(entry)
    if (entry.runtime === runtime && entry.targetId === targetId) return
    const wait = entry.shownAt + BROWSER_PREVIEW_SWITCH_HOLD_MS - now()
    if (entry.runtime === runtime && entry.targetId !== undefined && wait > 0) {
      entry.switchTimer = setTimer(() => {
        entry.switchTimer = undefined
        follow(entry, runtime, targetId)
        refreshInfo(entry)
        void reconcile(entry)
      }, wait)
      return
    }
    entry.runtime = runtime
    entry.targetId = targetId
    entry.shownAt = now()
    watchInfo(entry, runtime)
    if (entry.infoTimer !== undefined) clearTimer(entry.infoTimer)
    entry.infoTimer = undefined
    entry.infoRefreshedAt = Number.NEGATIVE_INFINITY
  }

  const startStream = async (entry: Session<Timer>, dimension: number): Promise<void> => {
    const { runtime, targetId } = entry
    if (runtime === undefined || targetId === undefined || runtime.connection.closed) return
    const cdpSession = runtime.sessions.get(targetId) ?? (await attachTarget(runtime, targetId))
    const dispose = runtime.connection.on(
      "Page.screencastFrame",
      (params) => {
        void runtime.connection
          .send("Page.screencastFrameAck", { sessionId: params.sessionId }, cdpSession)
          .catch(() => undefined)
        if (typeof params.data !== "string") return
        refreshInfo(entry)
        const data = params.data
        const watchers = [...entry.viewers].filter(([, watch]) => watch.watching)
        for (const [viewer] of watchers) viewer.frame(data)
      },
      cdpSession
    )
    entry.stream = { runtime, targetId, cdpSession, dimension, dispose }
    await runtime.connection.send(
      "Page.startScreencast",
      { format: "jpeg", quality: 70, maxWidth: dimension, maxHeight: dimension, everyNthFrame: 1 },
      cdpSession
    )
  }

  const reconcile = (entry: Session<Timer>): Promise<void> => {
    entry.pending = entry.pending.then(async () => {
      const dimension = desiredDimension(entry)
      const stream = entry.stream
      if (
        stream !== undefined &&
        (dimension === undefined ||
          stream.targetId !== entry.targetId ||
          stream.runtime !== entry.runtime ||
          stream.dimension !== dimension ||
          stream.runtime.connection.closed)
      )
        await stopStream(entry)
      if (dimension !== undefined && entry.stream === undefined) {
        await startStream(entry, dimension).catch(async () => {
          await stopStream(entry)
        })
      }
    })
    return entry.pending
  }

  return {
    activity: (sessionId: string, runtime: BrowserRuntime, targetId: string): Promise<void> => {
      const entry = session(sessionId)
      if (entry.idleTimer !== undefined) clearTimer(entry.idleTimer)
      entry.idleTimer = setTimer(() => {
        entry.idleTimer = undefined
        publish(entry, { state: "idle" })
        void reconcile(entry)
      }, IDLE_MS)
      publish(entry, { state: "active" })
      follow(entry, runtime, targetId)
      refreshInfo(entry)
      return reconcile(entry)
    },

    finish: (sessionId: string): Promise<void> => {
      const entry = sessions.get(sessionId)
      if (entry === undefined) return Promise.resolve()
      if (entry.idleTimer !== undefined) clearTimer(entry.idleTimer)
      entry.idleTimer = undefined
      if (entry.status.state === "active" || entry.status.state === "idle") {
        publish(entry, { state: "stopped" })
      }
      entry.runtime = undefined
      entry.targetId = undefined
      cancelSwitch(entry)
      stopInfo(entry)
      return reconcile(entry)
    },

    close: async (sessionId: string): Promise<void> => {
      const entry = sessions.get(sessionId)
      if (entry === undefined) return
      if (entry.idleTimer !== undefined) clearTimer(entry.idleTimer)
      entry.idleTimer = undefined
      if (entry.status.state !== "inactive") publish(entry, { state: "stopped" })
      entry.runtime = undefined
      entry.targetId = undefined
      cancelSwitch(entry)
      stopInfo(entry)
      await reconcile(entry)
      if (entry.viewers.size === 0) sessions.delete(sessionId)
    },

    subscribe: (sessionId: string, viewer: BrowserPreviewViewer): BrowserPreviewSubscription => {
      const entry = session(sessionId)
      entry.viewers.set(viewer, { watching: false, dimension: DEFAULT_DIMENSION })
      viewer.status(entry.status)
      return {
        watch: (dimension) => {
          if (!entry.viewers.has(viewer)) return
          entry.viewers.set(viewer, { watching: true, dimension: clampDimension(dimension) })
          void reconcile(entry)
        },
        unwatch: () => {
          if (!entry.viewers.has(viewer)) return
          entry.viewers.set(viewer, { watching: false, dimension: DEFAULT_DIMENSION })
          void reconcile(entry)
        },
        close: () => {
          if (!entry.viewers.delete(viewer)) return
          void reconcile(entry).then(() => {
            if (
              entry.viewers.size === 0 &&
              entry.runtime === undefined &&
              sessions.get(sessionId) === entry
            )
              sessions.delete(sessionId)
          })
        }
      }
    }
  }
}

export const makeBrowserPreviews = <Timer>(options: BrowserPreviewsOptions<Timer> = {}) => {
  const now = options.now ?? Date.now
  return options.setTimer === undefined
    ? createBrowserPreviews(nodeTimers, now)
    : createBrowserPreviews(options, now)
}

export type BrowserPreviews = ReturnType<typeof makeBrowserPreviews>
