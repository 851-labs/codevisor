import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import type { BrowserCursor } from "./browser-cursor.js"
import type { PointerState } from "./browser-input.js"
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
  /// "kept" marks tabs handed to the user at an earlier finalize: still visible to later
  /// turns, never closed by a later finalize.
  readonly sessionTargets: Map<string, Map<string, "created" | "claimed" | "kept">>
}

/// One tool call against the selected page, as the tool-family handlers see it.
export interface BrowserToolInvocation {
  readonly active: BrowserRuntime
  readonly args: Readonly<Record<string, unknown>>
  readonly backend: BrowserBackend
  /// The presented pointer for this session; every pointer action animates it first.
  readonly cursor: BrowserCursor
  readonly page: PageHandle
  /// Where the session's pointer is and which buttons and modifiers it holds.
  readonly pointer: PointerState
  readonly toolName: string
}
