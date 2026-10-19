import type { PluginManifest } from "@codevisor/api"

import type { PluginCandidatePreparerDeps } from "./plugin-candidate.js"
import { displayPluginCommand, pluginSetupCommands } from "./plugin-command.js"
import type { PluginInstallerDeps } from "./plugin-install.js"
import type { PluginProcessHandle } from "./plugin-supervisor.js"
import { PluginsError } from "./plugins-error.js"

export const makePluginSetup = (
  deps: PluginInstallerDeps,
  spawnShell: NonNullable<PluginInstallerDeps["spawnShell"]>,
  spawnArgv: NonNullable<PluginInstallerDeps["spawnArgv"]>,
  platform: string
): PluginCandidatePreparerDeps["runSetup"] => {
  const runSetupCommand = (
    command: ReturnType<typeof pluginSetupCommands>[number],
    manifest: PluginManifest,
    directory: string,
    env: NodeJS.ProcessEnv
  ): Promise<{ readonly ok: boolean; readonly message: string }> =>
    new Promise((resolvePromise) => {
      let child: PluginProcessHandle
      if (command.kind === "shell") {
        child = spawnShell(command.command, { cwd: directory, env })
      } else {
        child = spawnArgv(command.argv, { cwd: directory, env })
      }
      const terminal = deps.registerExternalTerminal?.(
        { normalizeNewlines: true, sessionId: `plugin-install:${manifest.id}` },
        { kill: () => child.kill(), resize: () => undefined, write: () => undefined }
      )
      terminal?.output(`$ ${displayPluginCommand(command)}\r\n`)
      child.onOutput?.((data) => terminal?.output(data))
      child.onExit((message, exitCode) => {
        terminal?.exit(exitCode ?? undefined)
        resolvePromise({ message, ok: exitCode === 0 })
      })
    })

  const runSetup = async (
    manifest: PluginManifest,
    directory: string,
    baseEnv: NodeJS.ProcessEnv,
    previousVersion: string | undefined
  ): Promise<void> => {
    const env: NodeJS.ProcessEnv = {
      ...baseEnv,
      CODEVISOR_PLUGIN_ID: manifest.id,
      CODEVISOR_PLUGIN_INSTALL_REASON: previousVersion === undefined ? "install" : "update",
      CODEVISOR_PLUGIN_VERSION: manifest.version
    }
    if (previousVersion !== undefined) {
      env["CODEVISOR_PLUGIN_PREVIOUS_VERSION"] = previousVersion
    }
    for (const command of pluginSetupCommands(manifest, platform)) {
      const outcome = await runSetupCommand(command, manifest, directory, env)
      if (!outcome.ok) {
        throw new PluginsError(
          "invalid",
          `Plugin ${manifest.id} setup command failed: ${outcome.message}`
        )
      }
    }
  }

  return runSetup
}
