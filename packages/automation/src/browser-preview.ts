import { attachTarget, type BrowserRuntime } from "./browser-cdp-engine.js"

/// What a chat's agent is doing in its browser, as the picture-in-picture
/// card shows it: `inactive` before any browser use, `active` while the agent
/// drives a tab, `idle` once it has paused, `stopped` when the turn ends.
export type BrowserPreviewState = "inactive" | "active" | "idle" | "stopped"

export interface BrowserPreviewStatus {
  readonly state: BrowserPreviewState
  readonly title: string
  readonly url: string
}

export interface BrowserPreviewViewer {
  readonly status: (status: BrowserPreviewStatus) => void
  /// One base64 JPEG of the tab's viewport.
  readonly frame: (data: string) => void
}

export interface BrowserPreviewSubscription {
  /// Start receiving frames, sized to fit `dimension` pixels on the long side.
  readonly watch: (dimension: number) => void
  readonly unwatch: () => void
  readonly close: () => void
}

export interface BrowserPreviewsOptions {
  /// How long a session without browser calls stays active before idling.
  readonly idleMs?: number
  readonly setTimer?: (callback: () => void, ms: number) => unknown
  readonly clearTimer?: (timer: unknown) => void
  readonly now?: () => number
}

export const BROWSER_PREVIEW_IDLE_MS = 60_000
const MIN_DIMENSION = 320
const MAX_DIMENSION = 1920
const DEFAULT_DIMENSION = 1280
const INFO_REFRESH_MS = 1_000

interface Stream {
  readonly runtime: BrowserRuntime
  readonly targetId: string
  readonly cdpSession: string
  readonly dimension: number
  readonly dispose: () => void
}

interface Session {
  status: BrowserPreviewStatus
  runtime: BrowserRuntime | undefined
  targetId: string | undefined
  readonly viewers: Map<BrowserPreviewViewer, { watching: boolean; dimension: number }>
  stream: Stream | undefined
  /// The reconcile in flight; reconciles run one at a time per session.
  pending: Promise<void>
  idleTimer: unknown
  infoRefreshedAt: number
  /// A title refresh deferred to the end of the current refresh window.
  infoTimer: unknown
  /// Follows the agent's tab's title and address as they change, in the
  /// browsers that report it; the rest refresh on each browser call.
  infoWatch: { readonly runtime: BrowserRuntime; readonly dispose: () => void } | undefined
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

/// Live previews of the tabs chats' agents drive, over CDP screencasts. A
/// screencast runs only while the agent is active and someone watches, and
/// follows the agent to whichever tab it selects. Works the same for every
/// backend: each speaks CDP for the tab, and the in-page agent cursor is part
/// of the frames.
export const makeBrowserPreviews = (options: BrowserPreviewsOptions = {}) => {
  const idleMs = options.idleMs ?? BROWSER_PREVIEW_IDLE_MS
  const setTimer = options.setTimer ?? ((callback, ms) => setTimeout(callback, ms).unref())
  const clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as NodeJS.Timeout))
  const now = options.now ?? Date.now
  const sessions = new Map<string, Session>()

  const session = (sessionId: string): Session => {
    const existing = sessions.get(sessionId)
    if (existing !== undefined) return existing
    const created: Session = {
      status: { state: "inactive", title: "", url: "" },
      runtime: undefined,
      targetId: undefined,
      stream: undefined,
      idleTimer: undefined,
      viewers: new Map(),
      pending: Promise.resolve(),
      infoRefreshedAt: Number.NEGATIVE_INFINITY,
      infoTimer: undefined,
      infoWatch: undefined
    }
    sessions.set(sessionId, created)
    return created
  }

  const watchInfo = (entry: Session, runtime: BrowserRuntime | undefined): void => {
    if (entry.infoWatch?.runtime === runtime) return
    entry.infoWatch?.dispose()
    entry.infoWatch =
      runtime === undefined
        ? undefined
        : {
            runtime,
            dispose: runtime.connection.on("Target.targetInfoChanged", (params) => {
              const info = params.targetInfo as
                | { readonly targetId?: unknown; readonly title?: unknown; readonly url?: unknown }
                | undefined
              if (info === undefined || info.targetId !== entry.targetId) return
              publish(entry, {
                title: typeof info.title === "string" ? info.title : "",
                url: typeof info.url === "string" ? info.url : ""
              })
            })
          }
  }

  /// Reads the agent's tab's title and address, at most once a second: a
  /// call inside the window runs at its end instead, so the last change in a
  /// burst (the page finishing loading) is never missed.
  const refreshInfo = (entry: Session): void => {
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

  const stopInfo = (entry: Session): void => {
    if (entry.infoTimer !== undefined) clearTimer(entry.infoTimer)
    entry.infoTimer = undefined
    watchInfo(entry, undefined)
  }

  const startStream = async (entry: Session, dimension: number): Promise<void> => {
    const { runtime, targetId } = entry
    if (runtime === undefined || targetId === undefined || runtime.connection.closed) return
    const cdpSession = runtime.sessions.get(targetId) ?? (await attachTarget(runtime, targetId))
    const dispose = runtime.connection.on(
      "Page.screencastFrame",
      (params) => {
        // Chrome sends the next frame only after this one is acknowledged.
        void runtime.connection
          .send("Page.screencastFrameAck", { sessionId: params.sessionId }, cdpSession)
          .catch(() => undefined)
        if (typeof params.data !== "string") return
        // A new frame often means a new title too.
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

  /// Brings the screencast in line with what the session wants: running on
  /// the agent's tab at the largest watched size, or stopped.
  const reconcile = (entry: Session): Promise<void> => {
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
          // The tab went away or can't be cast; the next activity retries.
          await stopStream(entry)
        })
      }
    })
    return entry.pending
  }

  return {
    /// The agent just used `targetId` in `runtime`: show it, live.
    activity: (sessionId: string, runtime: BrowserRuntime, targetId: string): Promise<void> => {
      const entry = session(sessionId)
      entry.runtime = runtime
      entry.targetId = targetId
      if (entry.idleTimer !== undefined) clearTimer(entry.idleTimer)
      entry.idleTimer = setTimer(() => {
        entry.idleTimer = undefined
        publish(entry, { state: "idle" })
        void reconcile(entry)
      }, idleMs)
      publish(entry, { state: "active" })
      watchInfo(entry, runtime)
      refreshInfo(entry)
      return reconcile(entry)
    },

    /// The turn ended: the agent is done with its tabs.
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
      stopInfo(entry)
      return reconcile(entry)
    },

    /// The session is gone; forget it once nobody is watching.
    close: async (sessionId: string): Promise<void> => {
      const entry = sessions.get(sessionId)
      if (entry === undefined) return
      if (entry.idleTimer !== undefined) clearTimer(entry.idleTimer)
      entry.idleTimer = undefined
      if (entry.status.state !== "inactive") publish(entry, { state: "stopped" })
      entry.runtime = undefined
      entry.targetId = undefined
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

export type BrowserPreviews = ReturnType<typeof makeBrowserPreviews>
