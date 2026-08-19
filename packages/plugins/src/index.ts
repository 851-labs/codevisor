export { PluginsError, type PluginsErrorCode } from "./plugins-error.js"
export { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
export {
  defaultPluginsRoot,
  MANAGED_PLUGIN_MARKER,
  MANAGED_PLUGIN_MARKER_CONTENT,
  scanPlugins,
  type InstalledPlugin,
  type InvalidPluginEntry,
  type PluginScan
} from "./plugin-store.js"
export { clonePluginSource, parsePluginSource, type ParsedPluginSource } from "./plugin-source.js"
export {
  makePluginInstaller,
  type PluginInstaller,
  type PluginInstallerDeps
} from "./plugin-install.js"
export { PANE_TOKEN_QUERY_PARAM } from "./plugin-pane-auth.js"
export {
  DEFAULT_PLUGIN_REGISTRY_URL,
  filterPluginRegistryIndex,
  makePluginRegistryClient,
  PLUGIN_REGISTRY_CACHE_TTL_MS,
  resolvePluginRegistryUrl,
  type PluginRegistryClient,
  type PluginRegistryClientConfig,
  type PluginRegistryFetch
} from "./plugin-registry.js"
export {
  makePluginsManager,
  type PluginsManager,
  type PluginsManagerConfig,
  type PluginStateEvent,
  type PluginToolInvocationContext,
  type PluginToolSummary
} from "./plugins-manager.js"
export type {
  PluginProcessHandle,
  PluginSpawnOptions,
  PluginSupervisorConfig,
  PluginTerminalConfig,
  PluginTerminalHandle,
  PluginTerminalProcess,
  RegisterPluginTerminal
} from "./plugin-supervisor.js"
export {
  managedPluginSkill,
  PLUGIN_AUTHORING_SKILL_DIRECTORY,
  type PluginSkillOptions,
  type PluginSkillSpec
} from "./plugin-skill.js"
