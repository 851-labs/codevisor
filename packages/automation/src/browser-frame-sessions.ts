import { delay, type CdpConnection } from "./browser-cdp.js"
import { recordOrUndefined } from "./unknown-values.js"

export interface FrameSessionRegistry {
  readonly connection: CdpConnection
  readonly sessions: Map<string, string>
  readonly frameParents: Map<string, string>
}

const frameAttachWaitMs = 2_000
const frameAttachPollMs = 25

export const enableSessionDomains = async (
  runtime: FrameSessionRegistry,
  sessionId: string
): Promise<void> => {
  await Promise.all([
    runtime.connection.sendOnce("Page.enable", {}, sessionId),
    runtime.connection.sendOnce("Network.enable", {}, sessionId),
    runtime.connection.sendOnce("Runtime.enable", {}, sessionId),
    runtime.connection.sendOnce("DOM.enable", {}, sessionId),
    runtime.connection.sendOnce("Accessibility.enable", {}, sessionId),
    runtime.connection.sendOnce("Log.enable", {}, sessionId).catch(() => undefined)
  ])
}

export const autoAttachFrames = (runtime: FrameSessionRegistry, sessionId: string): Promise<void> =>
  runtime.connection
    .sendOnce(
      "Target.setAutoAttach",
      {
        autoAttach: true,
        waitForDebuggerOnStart: false,
        flatten: true,
        filter: [{ type: "iframe" }]
      },
      sessionId
    )
    .then(
      () => undefined,
      () => undefined
    )

export const adoptFrameSession = (
  runtime: FrameSessionRegistry,
  parentSessionId: string | undefined,
  params: Readonly<Record<string, unknown>>
): void => {
  const target = recordOrUndefined(params.targetInfo)
  if (parentSessionId === undefined || typeof params.sessionId !== "string") return
  if (target?.type !== "iframe" || typeof target.targetId !== "string") return

  const sessionId = params.sessionId
  runtime.sessions.set(target.targetId, sessionId)
  runtime.frameParents.set(sessionId, parentSessionId)
  void enableSessionDomains(runtime, sessionId).catch(() => undefined)
  void autoAttachFrames(runtime, sessionId)
}

export const forgetFrameSessions = (
  runtime: FrameSessionRegistry,
  parentSessionId: string
): void => {
  for (const [sessionId, parent] of runtime.frameParents) {
    if (parent !== parentSessionId) continue
    runtime.frameParents.delete(sessionId)
    forgetFrameTarget(runtime, sessionId)
    forgetFrameSessions(runtime, sessionId)
  }
}

export const attachedFrameSession = async (
  runtime: FrameSessionRegistry,
  frameId: string
): Promise<string | undefined> => {
  const deadline = Date.now() + frameAttachWaitMs
  while (Date.now() < deadline) {
    const sessionId = runtime.sessions.get(frameId)
    if (sessionId !== undefined) return sessionId
    await delay(frameAttachPollMs)
  }
  return runtime.sessions.get(frameId)
}

const forgetFrameTarget = (runtime: FrameSessionRegistry, sessionId: string): void => {
  for (const [targetId, candidate] of runtime.sessions) {
    if (candidate === sessionId) runtime.sessions.delete(targetId)
  }
}
