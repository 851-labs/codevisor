import { realpathSync, existsSync } from "node:fs"
import { join, dirname } from "node:path"

import { locateExecutableOnPath } from "@codevisor/agent-runtime"
import type { HarnessUninstallInfo } from "@codevisor/api"
import { detectBrewPackage } from "@codevisor/updater"

import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import type { HarnessOperationRunner } from "./harness-lifecycle-execution.js"
import { run } from "./harness-lifecycle-support.js"

type UninstallPlan =
  | { available: false; detail: string }
  | {
      available: true
      target: string
      command: string
      extraEnv?: Readonly<Record<string, string>>
    }

const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`

export const makeHarnessUninstall = (
  core: HarnessLifecycleCore,
  runner: HarnessOperationRunner
) => {
  const resolvePlan = async (id: string): Promise<UninstallPlan> => {
    const definition = core.definitionOrThrow(id)
    const harness = (await run(core.config.agents.discoverHarnesses)).find((item) => item.id === id)
    const path = harness?.readiness.path
    if (path === undefined || harness?.readiness.state !== "ready") {
      return { available: false, detail: "Not installed" }
    }
    const resolve = core.config.realpath ?? realpathSync
    let target: string
    try {
      target = resolve(path)
    } catch {
      return { available: false, detail: "Installation not found" }
    }
    const env = await core.resolveEnv()
    const commandFor = (
      tool: string,
      args: string[],
      extraEnv?: Readonly<Record<string, string>>
    ): UninstallPlan => {
      const executable = locateExecutableOnPath(tool, env)
      return executable === undefined
        ? { available: false, detail: `${tool} is required to uninstall this installation` }
        : {
            available: true,
            command: [executable, ...args].map(quote).join(" "),
            target,
            ...(extraEnv === undefined ? {} : { extraEnv })
          }
    }
    const brew = detectBrewPackage(path, { realpath: resolve })
    if (brew !== undefined) {
      const base = brew.formula.split("@")[0]
      const owned = definition.installMethods?.some(
        (method) => method.kind === "brew" && method.formula?.split("@")[0] === base
      )
      if (owned)
        return commandFor("brew", ["uninstall", ...(brew.cask ? ["--cask"] : []), brew.formula])
    }
    // Infer the exact prefix from the owning global package, not the current
    // npm default (which may belong to a different Node installation).
    for (const method of definition.installMethods ?? []) {
      if (method.kind === "npm" && method.packageName !== undefined) {
        const marker = `/lib/node_modules/${method.packageName}/`
        const index = target.indexOf(marker)
        if (index > 0)
          return commandFor("npm", [
            "uninstall",
            "--global",
            "--ignore-scripts",
            "--prefix",
            target.slice(0, index),
            method.packageName
          ])
      }
      if (method.kind === "uv" && method.packageName !== undefined) {
        const marker = `/uv/tools/${method.packageName}/`
        const index = target.indexOf(marker)
        if (index >= 0)
          return commandFor("uv", ["tool", "uninstall", method.packageName], {
            UV_TOOL_DIR: target.slice(0, index) + "/uv/tools"
          })
      }
    }
    const home = core.config.home ?? env.HOME
    if (id === "codex" && home !== undefined) {
      const root = join(env.CODEX_HOME ?? join(home, ".codex"), "packages/standalone")
      const bin = join(env.CODEX_INSTALL_DIR ?? join(home, ".local/bin"), "codex")
      if (path === bin && target.startsWith(`${root}/releases/`) && resolve(root) === root) {
        const links = [path]
        const companion = join(dirname(path), "codex-code-mode-host")
        if (
          (core.config.pathExists ?? existsSync)(companion) &&
          resolve(companion).startsWith(`${root}/releases/`)
        ) {
          links.push(companion)
        }
        return {
          available: true,
          target,
          command: `/bin/rm -f -- ${links.map(quote).join(" ")} && /bin/rm -rf -- ${quote(root)}`
        }
      }
    }
    if (id === "claude-code" && home !== undefined && path === join(home, ".local/bin/claude")) {
      const versions = join(home, ".local/share/claude")
      if (target.startsWith(`${versions}/versions/`) && resolve(versions) === versions) {
        return {
          available: true,
          target,
          command: `/bin/rm -f -- ${quote(path)} && /bin/rm -rf -- ${quote(versions)}`
        }
      }
    }
    return {
      available: false,
      detail: target.includes(".app/")
        ? "Included with a desktop app. Disable this harness or uninstall the app separately."
        : "Uninstall this installation with its original installer."
    }
  }

  const release = (id: string): void => {
    core.uninstallRequests.delete(id)
    for (const listener of core.gateListeners) listener(id)
  }
  return {
    uninstallInfo: async (id: string): Promise<HarnessUninstallInfo> => {
      const plan = await resolvePlan(id)
      return plan.available ? { available: true, command: plan.command } : plan
    },
    beginUninstall: async (id: string) => {
      if ((core.busyCounts.get(id) ?? 0) > 0)
        throw new Error("Finish or stop active chats before uninstalling")
      const phase = core.operations.get(id)?.phase
      if (core.uninstallRequests.has(id) || (phase !== undefined && phase !== "failed")) {
        throw new Error("Another operation is in progress")
      }
      core.uninstallRequests.add(id)
      try {
        const plan = await resolvePlan(id)
        if (!plan.available) throw new Error(plan.detail)
        const target = plan.target
        return await runner.runOperation({
          harnessId: id,
          phase: "uninstalling",
          command: plan.command,
          ...(plan.extraEnv === undefined ? {} : { extraEnv: plan.extraEnv }),
          verify: async () => {
            if ((core.config.pathExists ?? existsSync)(target))
              throw new Error("The installation is still present")
          },
          onSettled: () => release(id)
        })
      } catch (cause) {
        core.setOperation(id, {
          phase: "failed",
          error: cause instanceof Error ? cause.message : String(cause)
        })
        release(id)
        throw cause
      }
    }
  }
}
