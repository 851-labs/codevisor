import type { DiscoverRemotePluginResult, PluginManifest } from "@codevisor/api"
import type { PluginInstallSourceReceipt } from "./plugin-receipt.js"
import { displayPluginCommand, pluginRunCommand, pluginSetupCommands } from "./plugin-command.js"
import { pluginConsentKey } from "./plugin-consent.js"

export const describePlugin = (
  manifest: PluginManifest,
  source: PluginInstallSourceReceipt,
  platform: string,
  alreadyInstalled: boolean
): DiscoverRemotePluginResult => {
  const runCommand = pluginRunCommand(manifest)
  const setupCommands = pluginSetupCommands(manifest, platform)
  return {
    consentKey: pluginConsentKey(manifest.id, source.url, source.subpath),
    ...(source.repo === undefined ? {} : { sourceRepo: source.repo }),
    ...(manifest.ageRating === undefined ? {} : { ageRating: manifest.ageRating }),
    alreadyInstalled: alreadyInstalled,
    id: manifest.id,
    name: manifest.name,
    panes: manifest.panes,
    runCommand: displayPluginCommand(runCommand),
    version: manifest.version,
    ...(manifest.description === undefined ? {} : { description: manifest.description }),
    ...(manifest.iconPath === undefined ? {} : { iconPath: manifest.iconPath }),
    ...(setupCommands.length === 0
      ? {}
      : { installCommand: setupCommands.map(displayPluginCommand).join(" && ") }),
    ...(manifest.protocolVersion === 1 || manifest.setup === undefined
      ? {}
      : { setupCommands: manifest.setup }),
    ...(manifest.protocolVersion === 1 || manifest.minCodevisorVersion === undefined
      ? {}
      : { minCodevisorVersion: manifest.minCodevisorVersion }),
    ...(manifest.protocolVersion === 1 || manifest.requirements === undefined
      ? {}
      : { requirements: manifest.requirements }),
    ...(manifest.tools === undefined ? {} : { tools: manifest.tools })
  }
}
