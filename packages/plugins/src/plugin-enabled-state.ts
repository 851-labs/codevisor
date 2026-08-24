import { existsSync } from "node:fs"
import { mkdir, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { PluginsError } from "./plugins-error.js"

const DISABLED_DIRECTORY = ".codevisor-disabled-plugins"

const markerPath = (pluginDataRoot: string, pluginId: string): string =>
  join(pluginDataRoot, DISABLED_DIRECTORY, pluginId)

/// Enabled is the default, so older installs migrate without a write.
export const isPluginEnabled = (pluginDataRoot: string, pluginId: string): boolean =>
  !existsSync(markerPath(pluginDataRoot, pluginId))

export const setPluginEnabledState = async (
  pluginDataRoot: string,
  pluginId: string,
  enabled: boolean
): Promise<void> => {
  const marker = markerPath(pluginDataRoot, pluginId)
  if (enabled) {
    await rm(marker, { force: true })
    return
  }
  await mkdir(join(pluginDataRoot, DISABLED_DIRECTORY), { recursive: true })
  await writeFile(marker, "Disabled by the user.\n", "utf8")
}

export const makePluginEnabledState = (pluginDataRoot: string) => ({
  assertEnabled: (pluginId: string): void => {
    if (!isPluginEnabled(pluginDataRoot, pluginId)) {
      throw new PluginsError("conflict", `Plugin ${pluginId} is disabled`)
    }
  },
  isEnabled: (pluginId: string): boolean => isPluginEnabled(pluginDataRoot, pluginId),
  persist: (pluginId: string, enabled: boolean): Promise<void> =>
    setPluginEnabledState(pluginDataRoot, pluginId, enabled)
})
