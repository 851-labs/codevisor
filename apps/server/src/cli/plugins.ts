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
  readonly tools?: ReadonlyArray<{ readonly name?: string; readonly description?: string }>
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

interface PluginUpdateStatus {
  readonly pluginId: string
  readonly installedVersion: string
  readonly state: string
  readonly registryVersion?: string
  readonly reason?: string
}

interface PluginUpdateReview {
  readonly version: string
  readonly setupCommands: ReadonlyArray<string>
  readonly runCommand: string
  readonly requirements?: {
    readonly executables?: ReadonlyArray<{
      readonly name: string
      readonly installHint?: string
      readonly helpUrl?: string
    }>
  }
}

interface PluginNamedChanges {
  readonly added: ReadonlyArray<string>
  readonly removed: ReadonlyArray<string>
  readonly changed: ReadonlyArray<string>
}

interface PluginUpdatePlan {
  readonly planId: string
  readonly pluginId: string
  readonly name: string
  readonly resolvedCommit: string
  readonly current: PluginUpdateReview
  readonly candidate: PluginUpdateReview
  readonly paneChanges: PluginNamedChanges
  readonly toolChanges: PluginNamedChanges
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
  // Declared agent tools are part of what the user consents to.
  for (const tool of plugin.tools ?? []) {
    deps.log(`  tool:    ${tool.name} — ${tool.description}`)
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

export const pluginUpdatesCommand = async (
  deps: PluginsCliDeps,
  options: CommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const response = await deps.fetchJson(`http://127.0.0.1:${port}/v1/plugins/updates`)
  if (response === undefined) return notRunning(deps, port)
  if (response.status !== 200) {
    deps.error(
      errorText(response.body, `Checking plugin updates failed (status ${response.status})`)
    )
    return 1
  }
  const updates =
    (response.body as { readonly updates?: ReadonlyArray<PluginUpdateStatus> }).updates ?? []
  if (updates.length === 0) {
    deps.log("No plugin updates to report.")
    return 0
  }
  for (const update of updates) {
    const target = update.registryVersion === undefined ? "" : ` -> ${update.registryVersion}`
    const reason = update.reason === undefined ? "" : ` — ${update.reason}`
    deps.log(`${update.pluginId}  ${update.installedVersion}${target}  ${update.state}${reason}`)
  }
  return 0
}

const printReviewCommands = (
  deps: PluginsCliDeps,
  label: string,
  review: PluginUpdateReview
): void => {
  if (review.setupCommands.length === 0) deps.log(`  ${label} setup: (none)`)
  for (const command of review.setupCommands) deps.log(`  ${label} setup: ${command}`)
  deps.log(`  ${label} run:   ${review.runCommand}`)
}

const printChanges = (deps: PluginsCliDeps, label: string, changes: PluginNamedChanges): void => {
  if (changes.added.length === 0 && changes.removed.length === 0 && changes.changed.length === 0) {
    deps.log(`  ${label}: (none)`)
    return
  }
  for (const name of changes.added) deps.log(`  ${label}: + ${name}`)
  for (const name of changes.changed) deps.log(`  ${label}: ~ ${name}`)
  for (const name of changes.removed) deps.log(`  ${label}: - ${name}`)
}

const printUpdatePlan = (deps: PluginsCliDeps, plan: PluginUpdatePlan): void => {
  deps.log(`${plan.name} ${plan.current.version} -> ${plan.candidate.version}`)
  deps.log(`  id:      ${plan.pluginId}`)
  deps.log(`  commit:  ${plan.resolvedCommit}`)
  deps.log("")
  deps.log("Commands:")
  printReviewCommands(deps, "current", plan.current)
  printReviewCommands(deps, "update ", plan.candidate)
  deps.log("")
  deps.log("Requirements:")
  const requirements = plan.candidate.requirements?.executables ?? []
  if (requirements.length === 0) deps.log("  (none declared)")
  for (const requirement of requirements) {
    deps.log(`  ${requirement.name}`)
    if (requirement.installHint !== undefined) deps.log(`    ${requirement.installHint}`)
    if (requirement.helpUrl !== undefined) deps.log(`    ${requirement.helpUrl}`)
  }
  deps.log("")
  deps.log("Capability changes:")
  printChanges(deps, "pane", plan.paneChanges)
  printChanges(deps, "tool", plan.toolChanges)
}

export interface PluginUpdateOptions extends CommandOptions {
  readonly pluginId: string
  /// Skip the prepared-plan confirmation (scripting / CI).
  readonly yes?: boolean | undefined
}

export const pluginUpdateCommand = async (
  deps: PluginsCliDeps,
  options: PluginUpdateOptions
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  const pluginPath = encodeURIComponent(options.pluginId)
  const prepared = await deps.fetchJson(
    `http://127.0.0.1:${port}/v1/plugins/${pluginPath}/update/prepare`,
    { method: "POST", timeoutMs: INSTALL_TIMEOUT_MS }
  )
  if (prepared === undefined) return notRunning(deps, port)
  if (prepared.status !== 201) {
    deps.error(errorText(prepared.body, `Preparing update failed (status ${prepared.status})`))
    return 1
  }
  const plan = prepared.body as PluginUpdatePlan
  printUpdatePlan(deps, plan)
  deps.log("")
  if (options.yes !== true) {
    const accepted = await deps.confirm(`Update ${plan.name} to ${plan.candidate.version}?`)
    if (!accepted) {
      deps.log("Cancelled.")
      return 1
    }
  }
  const applied = await deps.fetchJson(
    `http://127.0.0.1:${port}/v1/plugins/${pluginPath}/update/apply`,
    { body: { planId: plan.planId }, method: "POST", timeoutMs: INSTALL_TIMEOUT_MS }
  )
  if (applied === undefined) return notRunning(deps, port)
  if (applied.status !== 200) {
    deps.error(errorText(applied.body, `Update failed (status ${applied.status})`))
    return 1
  }
  const summary = applied.body as PluginSummary
  deps.log(`Updated ${summary.id} ${summary.version ?? ""}`.trim())
  return 0
}
