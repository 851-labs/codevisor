import {
  decode,
  isSemanticVersion,
  isSupportedPluginProtocolVersion,
  PluginManifest as PluginManifestSchema,
  type PluginExecutableRequirement,
  type PluginManifest,
  type PluginManifestV2,
  type PluginPaneDescriptor,
  type PluginToolDescriptor
} from "@codevisor/api"

import { PluginsError } from "./plugins-error.js"

export const PLUGIN_MANIFEST_FILENAME = "codevisor-plugin.json"

/// Owner-namespaced plugin id: lowercase `owner.name`. The dot is the
/// namespace separator, so exactly one is allowed; segments are constrained
/// to url/cookie/path-safe characters because the id appears in proxy paths
/// and cookie names.
const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/

/// Tool names appear as `plugin.<pluginId>.<toolName>` catalog paths, so they
/// must never contain the dot the path grammar splits on.
const PLUGIN_TOOL_NAME_PATTERN = /^[a-z0-9_]+$/
const EXECUTABLE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/

const validateServerPath = (label: string, path: string): void => {
  if (!path.startsWith("/") || path.includes("..") || path.includes("?") || path.includes("#")) {
    throw new PluginsError("invalid", `${label} must be a plain absolute path: ${path}`)
  }
}

/// Parses and validates a codevisor-plugin.json payload. Every rule here is
/// part of the plugin protocol: reject early with a message an author (or an
/// agent authoring a plugin) can act on, never let a malformed manifest reach
/// the supervisor or proxy.
export const parsePluginManifest = (raw: string): PluginManifest => {
  const json = parseManifestJson(raw)
  validateProtocolVersion(json)
  const manifest = decodeManifest(json)
  validatePluginId(manifest.id)
  validateCommands(manifest)
  validatePluginPaths(manifest)
  validatePanes(manifest.panes)
  validateTools(manifest.tools ?? [])
  return manifest
}

const parseManifestJson = (raw: string): unknown => {
  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch {
    throw new PluginsError("invalid", `${PLUGIN_MANIFEST_FILENAME} is not valid JSON`)
  }
  return json
}

const validateProtocolVersion = (json: unknown): void => {
  const protocolVersion =
    typeof json === "object" && json !== null && "protocolVersion" in json
      ? (json as { readonly protocolVersion?: unknown }).protocolVersion
      : undefined
  if (typeof protocolVersion === "number" && !isSupportedPluginProtocolVersion(protocolVersion)) {
    throw new PluginsError(
      "invalid",
      `Unsupported plugin protocolVersion ${protocolVersion} (this server supports 1 and 2)`
    )
  }
}

const decodeManifest = (json: unknown): PluginManifest => {
  let manifest: PluginManifest
  try {
    manifest = decode(PluginManifestSchema)(json)
  } catch (cause) {
    /* v8 ignore next -- Effect Schema decode failures are always Errors. */
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new PluginsError("invalid", `Invalid plugin manifest: ${message}`)
  }
  return manifest
}

const validatePluginId = (id: string): void => {
  if (!PLUGIN_ID_PATTERN.test(id)) {
    throw new PluginsError(
      "invalid",
      `Plugin id must be lowercase "owner.name" (letters, digits, hyphens): ${id}`
    )
  }
}

const validateCommands = (manifest: PluginManifest): void => {
  if (manifest.protocolVersion === 1) {
    if (manifest.run.command.trim().length === 0) {
      throw new PluginsError("invalid", "Plugin run.command must not be empty")
    }
  } else {
    validateV2Manifest(manifest)
  }
}

const validateV2Manifest = (manifest: PluginManifestV2): void => {
  if (!isSemanticVersion(manifest.version)) {
    throw new PluginsError("invalid", `Plugin version must be valid SemVer: ${manifest.version}`)
  }
  validateArgv("Plugin run.argv", manifest.run.argv)
  for (const [index, step] of (manifest.setup ?? []).entries()) {
    validateArgv(`Plugin setup[${index}].argv`, step.argv)
  }
  validateMinimumVersion(manifest.minCodevisorVersion)
  validateExecutables(manifest.requirements?.executables ?? [])
}

const validateMinimumVersion = (version: string | undefined): void => {
  if (version !== undefined && !isSemanticVersion(version)) {
    throw new PluginsError("invalid", `Plugin minCodevisorVersion must be valid SemVer: ${version}`)
  }
}

const validateExecutables = (requirements: ReadonlyArray<PluginExecutableRequirement>): void => {
  const seenExecutables = new Set<string>()
  for (const requirement of requirements) {
    validateExecutableName(requirement.name, seenExecutables)
    validateExecutableGuidance(requirement)
  }
}

const validateExecutableName = (name: string, seenExecutables: Set<string>): void => {
  if (!EXECUTABLE_NAME_PATTERN.test(name)) {
    throw new PluginsError(
      "invalid",
      `Required executable must be a command name without a path: ${name}`
    )
  }
  if (seenExecutables.has(name)) {
    throw new PluginsError("invalid", `Duplicate executable requirement: ${name}`)
  }
  seenExecutables.add(name)
}

const validateExecutableGuidance = (requirement: PluginExecutableRequirement): void => {
  if (requirement.installHint !== undefined && requirement.installHint.trim().length === 0) {
    throw new PluginsError(
      "invalid",
      `Executable ${requirement.name} installHint must not be empty`
    )
  }
  if (requirement.helpUrl !== undefined) {
    validateExecutableHelpUrl(requirement.name, requirement.helpUrl)
  }
}

const validateExecutableHelpUrl = (name: string, helpUrl: string): void => {
  let url: URL
  try {
    url = new URL(helpUrl)
  } catch {
    throw new PluginsError("invalid", `Executable ${name} helpUrl must be an HTTP URL`)
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new PluginsError("invalid", `Executable ${name} helpUrl must be an HTTP URL`)
  }
}

const validatePluginPaths = (manifest: PluginManifest): void => {
  if (manifest.iconPath !== undefined) {
    validateServerPath("Plugin iconPath", manifest.iconPath)
  }
  if (manifest.healthPath !== undefined) {
    validateServerPath("Plugin healthPath", manifest.healthPath)
  }
}

const validatePanes = (panes: ReadonlyArray<PluginPaneDescriptor>): void => {
  const seenPaneTypes = new Set<string>()
  for (const pane of panes) {
    if (seenPaneTypes.has(pane.type)) {
      throw new PluginsError("invalid", `Duplicate pane type: ${pane.type}`)
    }
    seenPaneTypes.add(pane.type)
    validatePanePaths(pane)
  }
}

const validatePanePaths = (pane: PluginPaneDescriptor): void => {
  validatePaneDocumentPath(pane.path)
  validateServerPath("Pane path", pane.path)
  if (pane.iconPath !== undefined) {
    validateServerPath(`Pane ${pane.type} iconPath`, pane.iconPath)
  }
}

const validatePaneDocumentPath = (path: string): void => {
  // Trailing-slash discipline is what makes relative URLs inside pane
  // documents resolve under the proxied prefix without HTML rewriting.
  if (!path.startsWith("/") || !path.endsWith("/")) {
    throw new PluginsError(
      "invalid",
      `Pane path must start and end with "/" so relative URLs resolve under the proxy prefix: ${path}`
    )
  }
}

const validateTools = (tools: ReadonlyArray<PluginToolDescriptor>): void => {
  const seenToolNames = new Set<string>()
  for (const tool of tools) {
    validateToolName(tool.name, seenToolNames)
    validateToolEndpoint(tool)
    validateToolInputSchema(tool)
  }
}

const validateToolName = (name: string, seenToolNames: Set<string>): void => {
  if (!PLUGIN_TOOL_NAME_PATTERN.test(name)) {
    throw new PluginsError(
      "invalid",
      `Tool name must be lowercase letters, digits, and underscores: ${name}`
    )
  }
  if (seenToolNames.has(name)) {
    throw new PluginsError("invalid", `Duplicate tool name: ${name}`)
  }
  seenToolNames.add(name)
}

const validateToolEndpoint = (tool: PluginToolDescriptor): void => {
  if (tool.description.trim().length === 0) {
    throw new PluginsError("invalid", `Tool ${tool.name} needs a non-empty description`)
  }
  // Tool paths are RPC endpoints, not documents: absolute, but with no
  // trailing-slash requirement — nothing resolves relative URLs under them.
  validateServerPath(`Tool ${tool.name} path`, tool.path)
}

const validateToolInputSchema = (tool: PluginToolDescriptor): void => {
  // The schema is passed through to agents verbatim, so the only structural
  // requirement is "a JSON object" (arrays and primitives are not schemas).
  if (
    tool.inputSchema !== undefined &&
    (typeof tool.inputSchema !== "object" ||
      tool.inputSchema === null ||
      Array.isArray(tool.inputSchema))
  ) {
    throw new PluginsError("invalid", `Tool ${tool.name} inputSchema must be a JSON object`)
  }
}

const validateArgv = (label: string, argv: ReadonlyArray<string>): void => {
  if (argv.length === 0 || argv[0]?.trim().length === 0) {
    throw new PluginsError("invalid", `${label} must name an executable`)
  }
}
