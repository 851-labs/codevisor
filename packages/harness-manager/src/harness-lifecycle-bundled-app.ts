import {
  locateExecutableOnPath,
  type HarnessDefinition,
  type HarnessUpdateSource
} from "@codevisor/agent-runtime"
import type { HarnessBundledApp } from "@codevisor/api"
import { isNewerVersion } from "@codevisor/updater"
import { basename } from "node:path"
import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import type { HarnessUpdateDetection } from "./harness-lifecycle-detection.js"
import type { HarnessOperationRunner } from "./harness-lifecycle-execution.js"
import { appBundlePath, sparkleFeedUrl } from "./harness-lifecycle-support.js"
import type { HarnessLifecycleManager } from "./harness-lifecycle-types.js"

export type BundledAppOperations = Pick<
  HarnessLifecycleManager,
  "beginBundledAppUpdate" | "bundledAppInfo"
>

const bundledAppSource = (definition: HarnessDefinition): HarnessUpdateSource | undefined =>
  definition.update?.sources.find(
    (source) => source.apply.kind === "appBundleSwap" && source.check.kind === "sparkle"
  )

/// Dual-install support: a harness whose binary is the user's own install
/// but which also ships inside a desktop app the user may want updated.
export const makeBundledAppOperations = (
  core: HarnessLifecycleCore,
  detection: HarnessUpdateDetection,
  runner: HarnessOperationRunner
): BundledAppOperations => {
  const { arch, definitionOrThrow, platform, readBundleShortVersion, resolveEnv } = core
  const { checkSource } = detection
  const { startBundleSwap } = runner

  const locateBundledBinary = async (
    definition: HarnessDefinition
  ): Promise<string | undefined> => {
    const env = await resolveEnv()
    for (const candidate of definition.fallbackPaths ?? []) {
      const path = locateExecutableOnPath(candidate, env)
      if (path !== undefined) return path
    }
    return undefined
  }

  const bundledAppTarget = async (
    harnessId: string
  ): Promise<
    | {
        readonly bundle: string
        readonly check: { readonly appcastUrl: string; readonly appcastUrlX64?: string }
      }
    | undefined
  > => {
    if (platform !== "darwin") return undefined
    const definition = definitionOrThrow(harnessId)
    const source = bundledAppSource(definition)
    if (source === undefined || source.check.kind !== "sparkle") return undefined
    const binary = await locateBundledBinary(definition)
    if (binary === undefined) return undefined
    const bundle =
      (source.apply.kind === "appBundleSwap" ? source.apply.bundlePath : undefined) ??
      appBundlePath(binary)
    if (bundle === undefined) return undefined
    return { bundle, check: source.check }
  }

  const bundledAppInfo = async (harnessId: string): Promise<HarnessBundledApp | undefined> => {
    const target = await bundledAppTarget(harnessId)
    if (target === undefined) return undefined
    const installedVersion = await readBundleShortVersion(target.bundle)
    const latest = await checkSource({
      apply: { kind: "appBundleSwap" },
      check: { kind: "sparkle", ...target.check },
      when: "appBundle"
    })
    return {
      appName: basename(target.bundle).replace(/\.app$/, ""),
      bundlePath: target.bundle,
      updateAvailable:
        installedVersion !== undefined &&
        latest.latestVersion !== undefined &&
        isNewerVersion(latest.latestVersion, installedVersion),
      ...(installedVersion === undefined ? {} : { installedVersion }),
      ...(latest.latestVersion === undefined ? {} : { latestVersion: latest.latestVersion })
    }
  }

  const beginBundledAppUpdate = async (harnessId: string): Promise<void> => {
    const target = await bundledAppTarget(harnessId)
    if (target === undefined) {
      throw new Error(`${harnessId} has no bundled desktop app`)
    }
    const latest = await checkSource({
      apply: { kind: "appBundleSwap" },
      check: { kind: "sparkle", ...target.check },
      when: "appBundle"
    })
    startBundleSwap({
      appcastUrl: sparkleFeedUrl(arch, target.check),
      bundle: target.bundle,
      harnessId,
      recordsHarnessVersion: false,
      ...(latest.latestVersion === undefined ? {} : { targetVersion: latest.latestVersion })
    })
  }

  return { beginBundledAppUpdate, bundledAppInfo }
}
