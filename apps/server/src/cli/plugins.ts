/// `codevisor plugin …` — install, link, list, and remove plugins by talking
/// to the RUNNING server over its loopback API (never by touching the store
/// directly, so scans, supervision, and events stay consistent). Same
/// injectable-seam style as support.ts; the confirm prompt is wired in
/// cli.ts.
import { resolve } from "node:path"
import { resolvePort, type CliDeps, type CommandOptions } from "./support.js"

export interface PluginsCliDeps extends CliDeps {
  /// Install consent prompt; resolves false to abort. `--yes` skips it.
  readonly confirm: (message: string) => Promise<boolean>
}

/// Clone + dependency install can be slow; give server-side installs the
/// same generous window the harness installers get.
const INSTALL_TIMEOUT_MS = 10 * 60 * 1000

interface DiscoveredPlugin {
  readonly id?: string
  readonly name?: string
  readonly version?: string
  readonly description?: string
  readonly panes?: ReadonlyArray<{ readonly title?: string; readonly type?: string }>
  readonly installCommand?: string
  readonly runCommand?: string
  readonly alreadyInstalled?: boolean
}

interface PluginSummary {
  readonly id?: string
  readonly name?: string
  readonly version?: string
  readonly source?: string
  readonly state?: string
}

const errorText = (body: unknown, fallback: string): string => {
  const message = (body as { readonly error?: string } | undefined)?.error
  return message === undefined || message === "" ? fallback : message
}

const notRunning = (deps: CliDeps, port: number): number => {
  deps.error(`Codevisor server is not running on port ${port}; start it first: codevisor start`)
  return 1
}

export interface PluginInstallOptions extends CommandOptions {
  readonly source: string
  /// Skip the consent prompt (scripting / CI).
  readonly yes?: boolean | undefined
}

export const pluginInstallCommand = async (
  deps: PluginsCliDeps,
  options: PluginInstallOptions
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const discovered = await deps.fetchJson(`http://127.0.0.1:${port}/v1/plugins/discover-remote`, {
    body: { source: options.source },
    method: "POST",
    timeoutMs: INSTALL_TIMEOUT_MS
  })
  if (discovered === undefined) return notRunning(deps, port)
  if (discovered.status !== 200) {
    deps.error(errorText(discovered.body, `Discovery failed (status ${discovered.status})`))
    return 1
  }
  const plugin = discovered.body as DiscoveredPlugin
  deps.log(`${plugin.name ?? plugin.id} ${plugin.version ?? ""}`.trim())
  deps.log(`  id:      ${plugin.id}`)
  if (plugin.description !== undefined) deps.log(`  about:   ${plugin.description}`)
  for (const pane of plugin.panes ?? []) {
    deps.log(`  pane:    ${pane.title} (${pane.type})`)
  }
  if (plugin.alreadyInstalled === true) {
    deps.log("  note:    a plugin with this id is already installed; this will update it")
  }
  deps.log("")
  deps.log("Installing will run these commands on your machine:")
  if (plugin.installCommand !== undefined) deps.log(`  install: ${plugin.installCommand}`)
  deps.log(`  run:     ${plugin.runCommand}`)
  deps.log("")
  if (options.yes !== true) {
    const accepted = await deps.confirm(`Install ${plugin.name ?? plugin.id}?`)
    if (!accepted) {
      deps.log("Cancelled.")
      return 1
    }
  }
  const imported = await deps.fetchJson(`http://127.0.0.1:${port}/v1/plugins/import-remote`, {
    body: { source: options.source },
    method: "POST",
    timeoutMs: INSTALL_TIMEOUT_MS
  })
  if (imported === undefined) return notRunning(deps, port)
  if (imported.status !== 201) {
    deps.error(errorText(imported.body, `Install failed (status ${imported.status})`))
    return 1
  }
  const summary = imported.body as PluginSummary
  deps.log(`Installed ${summary.id} ${summary.version ?? ""}`.trim())
  return 0
}

export interface PluginLinkOptions extends CommandOptions {
  readonly path: string
}

export const pluginLinkCommand = async (
  deps: PluginsCliDeps,
  options: PluginLinkOptions
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const linked = await deps.fetchJson(`http://127.0.0.1:${port}/v1/plugins/link`, {
    // The server needs an absolute path; resolve relative ones against the
    // caller's working directory (CLI and server share a machine).
    body: { path: resolve(options.path) },
    method: "POST"
  })
  if (linked === undefined) return notRunning(deps, port)
  if (linked.status !== 201) {
    deps.error(errorText(linked.body, `Link failed (status ${linked.status})`))
    return 1
  }
  const summary = linked.body as PluginSummary
  deps.log(`Linked ${summary.id} ${summary.version ?? ""}`.trim())
  return 0
}

export const pluginListCommand = async (
  deps: PluginsCliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(`http://127.0.0.1:${port}/v1/plugins`)
  if (response === undefined) return notRunning(deps, port)
  if (response.status !== 200) {
    deps.error(errorText(response.body, `Listing plugins failed (status ${response.status})`))
    return 1
  }
  const plugins =
    (response.body as { readonly plugins?: ReadonlyArray<PluginSummary> }).plugins ?? []
  if (plugins.length === 0) {
    deps.log("No plugins installed. Install one with: codevisor plugin install owner/repo")
    return 0
  }
  for (const plugin of plugins) {
    deps.log(
      `${plugin.id}  ${plugin.version ?? ""}  ${plugin.source ?? ""}  ${plugin.state ?? ""}  ${plugin.name ?? ""}`
    )
  }
  return 0
}

export interface PluginRemoveOptions extends CommandOptions {
  readonly pluginId: string
}

export const pluginRemoveCommand = async (
  deps: PluginsCliDeps,
  options: PluginRemoveOptions
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const removed = await deps.fetchJson(
    `http://127.0.0.1:${port}/v1/plugins/${encodeURIComponent(options.pluginId)}`,
    { method: "DELETE" }
  )
  if (removed === undefined) return notRunning(deps, port)
  if (removed.status !== 200) {
    deps.error(errorText(removed.body, `Remove failed (status ${removed.status})`))
    return 1
  }
  deps.log(`Removed ${options.pluginId}`)
  return 0
}
