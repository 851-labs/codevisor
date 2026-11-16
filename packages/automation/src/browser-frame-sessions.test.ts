import { expect, it } from "vitest"

import { attachTarget, discardTargetState } from "./browser-cdp-engine.js"
import { adoptFrameSession } from "./browser-frame-sessions.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"

const frame = (targetId: string, sessionId: string, type = "iframe") => ({
  sessionId,
  targetInfo: { targetId, type }
})

const recordedRuntime = () => {
  const sent: Array<readonly [string, string | undefined]> = []
  const runtime = fakeBrowserRuntime({
    connection: fakeCdpConnection({
      sendOnce: async (method, _params, sessionId) => {
        sent.push([method, sessionId])
        return method === "Target.attachToTarget" ? { sessionId: "page-session" } : {}
      }
    }).connection
  })
  return { runtime, sent }
}

it("watches a page for out-of-process frames and uses the session the browser attaches", async () => {
  const { runtime, sent } = recordedRuntime()

  expect(await attachTarget(runtime, "page")).toBe("page-session")
  expect(sent).toContainEqual(["Target.setAutoAttach", "page-session"])

  adoptFrameSession(runtime, "page-session", frame("frame", "frame-session"))
  sent.length = 0
  expect(await attachTarget(runtime, "frame", "page-session")).toBe("frame-session")
  expect(sent.map(([method]) => method)).not.toContain("Target.attachToTarget")
})

it("prepares each adopted frame, ignores other targets, and forgets frames with their page", () => {
  const { runtime, sent } = recordedRuntime()
  runtime.sessions.set("page", "page-session")

  adoptFrameSession(runtime, "page-session", frame("worker", "worker-session", "worker"))
  adoptFrameSession(runtime, undefined, frame("orphan", "orphan-session"))
  adoptFrameSession(runtime, "page-session", frame("outer", "outer-session"))
  adoptFrameSession(runtime, "outer-session", frame("inner", "inner-session"))
  expect([...runtime.sessions.keys()]).toEqual(["page", "outer", "inner"])
  expect(sent).toContainEqual(["Runtime.enable", "inner-session"])
  expect(sent).toContainEqual(["Target.setAutoAttach", "outer-session"])

  discardTargetState(runtime, "page")
  expect(runtime.sessions.size).toBe(0)
  expect(runtime.frameParents.size).toBe(0)
})
