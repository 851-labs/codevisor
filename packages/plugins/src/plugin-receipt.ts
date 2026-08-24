import { existsSync, readFileSync } from "node:fs"
import { rename, writeFile } from "node:fs/promises"
import { join } from "node:path"

export const PLUGIN_INSTALL_RECEIPT_FILENAME = ".codevisor-install.json"

export interface PluginInstallSourceReceipt {
  readonly kind: "github" | "git" | "local"
  readonly url: string
  readonly repo?: string
  readonly requestedRef?: string
  readonly subpath?: string
  readonly tracking: "registry" | "pinned"
}

export interface PluginInstallReceipt {
  readonly schemaVersion: 1
  readonly pluginId: string
  readonly source: PluginInstallSourceReceipt
  readonly resolvedCommit: string
  readonly installedVersion: string
  readonly installedAt: string
  readonly updatedAt: string
}

export const readPluginInstallReceipt = (
  pluginDirectory: string
): PluginInstallReceipt | undefined => {
  const path = join(pluginDirectory, PLUGIN_INSTALL_RECEIPT_FILENAME)
  if (!existsSync(path)) return undefined
  try {
    const value = JSON.parse(readFileSync(path, "utf8")) as unknown
    return isPluginInstallReceipt(value) ? value : undefined
  } catch {
    return undefined
  }
}

/// Writes through a sibling temporary file so a crash cannot leave a partial
/// receipt that loses the plugin's update provenance.
export const writePluginInstallReceipt = async (
  pluginDirectory: string,
  receipt: PluginInstallReceipt
): Promise<void> => {
  const path = join(pluginDirectory, PLUGIN_INSTALL_RECEIPT_FILENAME)
  const temporary = `${path}.tmp`
  await writeFile(temporary, `${JSON.stringify(receipt, undefined, 2)}\n`, "utf8")
  await rename(temporary, path)
}

const isPluginInstallReceipt = (value: unknown): value is PluginInstallReceipt => {
  if (typeof value !== "object" || value === null) return false
  const receipt = value as Partial<PluginInstallReceipt>
  const source = receipt.source as Partial<PluginInstallSourceReceipt> | undefined
  return (
    receipt.schemaVersion === 1 &&
    nonEmpty(receipt.pluginId) &&
    typeof receipt.resolvedCommit === "string" &&
    /^[0-9a-f]{40}$/i.test(receipt.resolvedCommit) &&
    nonEmpty(receipt.installedVersion) &&
    validDate(receipt.installedAt) &&
    validDate(receipt.updatedAt) &&
    source !== undefined &&
    (source.kind === "github" || source.kind === "git" || source.kind === "local") &&
    nonEmpty(source.url) &&
    (source.tracking === "registry" || source.tracking === "pinned") &&
    (source.repo === undefined || nonEmpty(source.repo)) &&
    (source.requestedRef === undefined || nonEmpty(source.requestedRef)) &&
    (source.subpath === undefined || nonEmpty(source.subpath))
  )
}

const nonEmpty = (value: unknown): value is string => typeof value === "string" && value.length > 0

const validDate = (value: unknown): value is string =>
  nonEmpty(value) && Number.isFinite(Date.parse(value))
