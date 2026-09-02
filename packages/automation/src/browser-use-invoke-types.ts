import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import type { BrowserBackend } from "./browser-use-provider.js"

export interface BrowserAssetInventory {
  readonly pageUrl: string
  readonly assets: ReadonlyArray<{
    readonly id: string
    readonly url: string
    readonly kind: string
    readonly name: string
    readonly sources: ReadonlyArray<Readonly<Record<string, unknown>>>
  }>
  readonly inlineSvgs: ReadonlyArray<{
    readonly id: string
    readonly markup: string
    readonly name: string
  }>
}

export interface BrowserToolSessionState {
  readonly assetInventories: Map<string, BrowserAssetInventory>
  readonly assetsDir: string
  readonly downloadsDir: string
  readonly selectedTargets: Map<string, string>
  readonly sessionBackends: Map<string, BrowserBackend>
  readonly sessionDispositions: Map<string, Map<string, "deliverable" | "handoff">>
  readonly sessionTargets: Map<string, Map<string, "created" | "claimed">>
}

/// One tool call against the selected page, as the tool-family handlers see it.
export interface BrowserToolInvocation {
  readonly active: BrowserRuntime
  readonly args: Readonly<Record<string, unknown>>
  readonly backend: BrowserBackend
  readonly page: PageHandle
  readonly toolName: string
}
