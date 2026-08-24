import type { PluginManifest } from "@codevisor/api"
import type { PluginInstallReceipt, PluginInstallSourceReceipt } from "./plugin-receipt.js"

export interface StagedPlugin {
  readonly manifest: PluginManifest
  readonly manifestRaw: string
  readonly root: string
  readonly env: NodeJS.ProcessEnv
  readonly resolvedCommit: string
  readonly source: PluginInstallSourceReceipt
  readonly cleanup: () => Promise<void>
}

export interface PreparedCandidateContext {
  readonly hadExisting: boolean
  readonly previousManifest?: PluginManifest
  readonly previousReceipt?: PluginInstallReceipt
}

export interface PreparePluginUpdateRequest {
  readonly expectedPluginId: string
  readonly planId: string
  readonly source: string
  readonly sourceReceipt: PluginInstallSourceReceipt
}

/// Opaque handle to candidate bytes already fetched, checked, and prepared on
/// the plugins filesystem. Only PluginInstaller may apply its directory.
export interface PreparedPluginUpdate {
  readonly directory: string
  readonly manifest: PluginManifest
  readonly planId: string
  readonly pluginId: string
  readonly previousManifest: PluginManifest
  readonly previousResolvedCommit: string
  readonly resolvedCommit: string
}
