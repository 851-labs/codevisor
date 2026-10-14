import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import type { AutomationProviderContext } from "./automation-provider.js"
import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { serializedBrowserOperation } from "./browser-runtime-lifecycle.js"
import { runtimeKey } from "./browser-use-invoke.js"
import type { BrowserBackend } from "./browser-use-provider-types.js"

export type SessionTargets = Map<string, Map<string, "created" | "claimed">>

type FinalizeTabs = (
  context: AutomationProviderContext,
  active: BrowserRuntime,
  toolName: "finalizeTabs",
  args: Readonly<Record<string, unknown>>,
  backend: BrowserBackend
) => Promise<CallToolResult>

export const trackPopups = (
  sessionTargets: SessionTargets,
  key: string,
  active: BrowserRuntime
): void => {
  active.eventDisposers.push(
    active.connection.on("Target.targetCreated", (params) => {
      const info = params.targetInfo as
        | { readonly targetId?: unknown; readonly type?: unknown; readonly openerId?: unknown }
        | undefined
      if (
        typeof info?.targetId !== "string" ||
        info.type !== "page" ||
        typeof info.openerId !== "string"
      )
        return
      for (const [sessionKey, targets] of sessionTargets) {
        if (!sessionKey.startsWith(`${key}:`) || !targets.has(info.openerId)) continue
        if (!targets.has(info.targetId)) targets.set(info.targetId, "created")
        return
      }
    })
  )
}

export const finishSessionTabs = async (
  context: AutomationProviderContext,
  sessionTargets: SessionTargets,
  runtimes: ReadonlyMap<string, Promise<BrowserRuntime>>,
  finalize: FinalizeTabs
): Promise<void> => {
  let failure: unknown
  for (const backend of ["builtin", "managed", "extension"] as const) {
    const key = runtimeKey(context, backend)
    if (!sessionTargets.has(`${key}:${context.sessionId}`)) continue
    const active = await runtimes.get(key)?.catch(() => undefined)
    if (active === undefined || active.connection.closed) continue
    await serializedBrowserOperation(active, () =>
      finalize(context, active, "finalizeTabs", { native: true }, backend)
    ).catch((cause: unknown) => {
      failure ??= cause
    })
  }
  if (failure !== undefined) throw failure
}
