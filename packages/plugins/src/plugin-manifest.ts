import {
  decode,
  PLUGINS_PROTOCOL_VERSION,
  PluginManifest as PluginManifestSchema,
  type PluginManifest
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
  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch {
    throw new PluginsError("invalid", `${PLUGIN_MANIFEST_FILENAME} is not valid JSON`)
  }
  let manifest: PluginManifest
  try {
    manifest = decode(PluginManifestSchema)(json)
  } catch (cause) {
    /* v8 ignore next -- Effect Schema decode failures are always Errors. */
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new PluginsError("invalid", `Invalid plugin manifest: ${message}`)
  }
  if (manifest.protocolVersion !== PLUGINS_PROTOCOL_VERSION) {
    throw new PluginsError(
      "invalid",
      `Unsupported plugin protocolVersion ${manifest.protocolVersion} (this server supports ${PLUGINS_PROTOCOL_VERSION})`
    )
  }
  if (!PLUGIN_ID_PATTERN.test(manifest.id)) {
    throw new PluginsError(
      "invalid",
      `Plugin id must be lowercase "owner.name" (letters, digits, hyphens): ${manifest.id}`
    )
  }
  if (manifest.run.command.trim().length === 0) {
    throw new PluginsError("invalid", "Plugin run.command must not be empty")
  }
  if (manifest.iconPath !== undefined) {
    validateServerPath("Plugin iconPath", manifest.iconPath)
  }
  const seenPaneTypes = new Set<string>()
  for (const pane of manifest.panes) {
    if (seenPaneTypes.has(pane.type)) {
      throw new PluginsError("invalid", `Duplicate pane type: ${pane.type}`)
    }
    seenPaneTypes.add(pane.type)
    // Trailing-slash discipline is what makes relative URLs inside pane
    // documents resolve under the proxied prefix without HTML rewriting.
    if (!pane.path.startsWith("/") || !pane.path.endsWith("/")) {
      throw new PluginsError(
        "invalid",
        `Pane path must start and end with "/" so relative URLs resolve under the proxy prefix: ${pane.path}`
      )
    }
    validateServerPath("Pane path", pane.path)
    if (pane.iconPath !== undefined) {
      validateServerPath(`Pane ${pane.type} iconPath`, pane.iconPath)
    }
  }
  const seenToolNames = new Set<string>()
  for (const tool of manifest.tools ?? []) {
    if (!PLUGIN_TOOL_NAME_PATTERN.test(tool.name)) {
      throw new PluginsError(
        "invalid",
        `Tool name must be lowercase letters, digits, and underscores: ${tool.name}`
      )
    }
    if (seenToolNames.has(tool.name)) {
      throw new PluginsError("invalid", `Duplicate tool name: ${tool.name}`)
    }
    seenToolNames.add(tool.name)
    if (tool.description.trim().length === 0) {
      throw new PluginsError("invalid", `Tool ${tool.name} needs a non-empty description`)
    }
    // Tool paths are RPC endpoints, not documents: absolute, but with no
    // trailing-slash requirement — nothing resolves relative URLs under them.
    validateServerPath(`Tool ${tool.name} path`, tool.path)
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
  return manifest
}
