import type {
  HarnessDefinition,
  HarnessUpdateSource,
  InstallOrigin
} from "@codevisor/agent-runtime"
import type { Harness, HarnessUpdateInfo } from "@codevisor/api"
import {
  checkBrewLatest,
  checkGithubLatest,
  checkNpmLatest,
  detectBrewPackage,
  detectInstallOrigin,
  isNewerVersion,
  parseAppcast,
  selectLatestAppcastItem,
  type LatestVersionResult
} from "@codevisor/updater"
import type { HarnessLifecycleCore } from "./harness-lifecycle-core.js"
import { appBundlePath, run } from "./harness-lifecycle-support.js"
import type { HarnessUpdateCheckOutcome } from "./harness-lifecycle-types.js"

const delay = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, milliseconds))

const meaningfullyChanged = (
  previous: HarnessUpdateInfo | undefined,
  next: HarnessUpdateInfo
): boolean =>
  previous === undefined ||
  previous.updateAvailable !== next.updateAvailable ||
  previous.latestVersion !== next.latestVersion ||
  previous.installedVersion !== next.installedVersion

export const matchSource = (
  definition: HarnessDefinition,
  origin: InstallOrigin
): HarnessUpdateSource | undefined => {
  const sources = definition.update?.sources ?? []
  return sources.find((source) => source.when === origin) ?? sources.find((s) => s.when === "any")
}

/// Update detection: latest-version lookups per source, the cached/coalesced
/// check across every harness, and the local re-probe that verifies an
/// update actually landed.
export const makeHarnessUpdateDetection = (core: HarnessLifecycleCore) => {
  const {
    arch,
    checkCacheMs,
    checkState,
    config,
    emit,
    fetchImpl,
    loadStates,
    now,
    platform,
    readBundleShortVersion,
    updateVerificationPollIntervalMs,
    updateVerificationTimeoutMs
  } = core

  const checkSource = async (
    source: HarnessUpdateSource,
    binaryPath?: string
  ): Promise<LatestVersionResult> => {
    switch (source.check.kind) {
      case "npm":
        return checkNpmLatest(source.check.packageName, source.check.distTag ?? "latest", fetchImpl)
      case "brew": {
        const formula =
          source.check.formula ??
          (binaryPath === undefined
            ? undefined
            : detectBrewPackage(
                binaryPath,
                config.realpath === undefined ? {} : { realpath: config.realpath }
              )?.formula)
        return formula === undefined ? {} : checkBrewLatest(formula, fetchImpl)
      }
      case "github":
        return checkGithubLatest(source.check.repo, fetchImpl)
      case "sparkle": {
        const url =
          arch === "x64" && source.check.appcastUrlX64 !== undefined
            ? source.check.appcastUrlX64
            : source.check.appcastUrl
        try {
          const response = await fetchImpl(url, { signal: AbortSignal.timeout(10_000) })
          if (!response.ok) return {}
          const item = selectLatestAppcastItem(parseAppcast(await response.text()))
          return item?.shortVersion === undefined
            ? {}
            : { channel: "app", latestVersion: item.shortVersion }
        } catch {
          return {}
        }
      }
    }
  }

  const checkHarness = async (
    definition: HarnessDefinition,
    harness: Harness
  ): Promise<HarnessUpdateCheckOutcome | undefined> => {
    const path = harness.readiness.path
    if (harness.readiness.state !== "ready" || path === undefined) return undefined
    const origin = detectInstallOrigin(path, {
      ...(config.home === undefined ? {} : { home: config.home }),
      ...(config.realpath === undefined ? {} : { realpath: config.realpath })
    })
    const source = matchSource(definition, origin)
    if (source === undefined) return undefined
    // App-bundle installs update via the app, so both sides of the version
    // comparison must be app versions — never the CLI's own --version, whose
    // channel runs ahead of the stable lines.
    let installedVersion = harness.readiness.version
    if (source.apply.kind === "appBundleSwap") {
      if (platform !== "darwin") return undefined
      const bundle = source.apply.bundlePath ?? appBundlePath(path)
      if (bundle === undefined) return undefined
      installedVersion = await readBundleShortVersion(bundle)
    }
    const latest = await checkSource(source, path)
    const updateAvailable =
      installedVersion !== undefined &&
      latest.latestVersion !== undefined &&
      isNewerVersion(latest.latestVersion, installedVersion)
    const info: HarnessUpdateInfo = {
      updateAvailable,
      installOrigin: origin,
      source: source.check.kind,
      checkedAt: new Date(now()).toISOString(),
      ...(installedVersion === undefined ? {} : { installedVersion }),
      ...(latest.latestVersion === undefined ? {} : { latestVersion: latest.latestVersion }),
      ...(latest.channel === undefined ? {} : { channel: latest.channel })
    }
    return { harnessId: definition.id, info }
  }

  const checkForUpdates = async (
    force = false
  ): Promise<ReadonlyArray<HarnessUpdateCheckOutcome>> => {
    if (checkState.inFlight !== undefined) return checkState.inFlight
    if (!force && now() - checkState.lastCheckAt < checkCacheMs) return []
    checkState.inFlight = (async () => {
      const current = await loadStates()
      const harnesses = await run(config.agents.discoverHarnesses)
      const outcomes: Array<HarnessUpdateCheckOutcome> = []
      await Promise.all(
        config.agents.catalog
          .filter((definition) => definition.update !== undefined)
          .map(async (definition) => {
            const harness = harnesses.find((candidate) => candidate.id === definition.id)
            if (harness === undefined) return
            try {
              const outcome = await checkHarness(definition, harness)
              if (outcome === undefined) return
              outcomes.push(outcome)
              const previous = current.get(outcome.harnessId)
              current.set(outcome.harnessId, outcome.info)
              await run(
                config.db.setHarnessUpdateState({
                  harnessId: outcome.harnessId,
                  info: outcome.info
                })
              ).catch(() => undefined)
              if (meaningfullyChanged(previous, outcome.info)) {
                emit({
                  kind: "harness.lifecycle.updated",
                  payload: { harnessId: outcome.harnessId, updateInfo: outcome.info },
                  subjectId: outcome.harnessId
                })
              }
            } catch {
              // One harness's failed check must not block the others.
            }
          })
      )
      checkState.lastCheckAt = now()
      return outcomes
    })().finally(() => {
      checkState.inFlight = undefined
    })
    return checkState.inFlight
  }

  /// A completion check must never reuse a probe that began before the
  /// updater changed the binary. Drain that work first, then force one new
  /// check; concurrent callers naturally share the newly-created inFlight.
  const checkForUpdatesFresh = async (): Promise<void> => {
    const previous = checkState.inFlight
    if (previous !== undefined) await previous.catch(() => undefined)
    checkState.lastCheckAt = 0
    await checkForUpdates(true).catch(() => undefined)
  }

  /// Re-probes the local harness until it reaches the version the user was
  /// offered. This is deliberately independent of the remote feed: a feed
  /// outage after a successful install must not make a completed update look
  /// unfinished, and a zero-exit no-op must not be reported as success.
  const waitForInstalledTarget = async (
    harnessId: string,
    targetVersion: string
  ): Promise<string> => {
    const deadline = Date.now() + updateVerificationTimeoutMs
    let observedVersion: string | undefined
    while (true) {
      await run(config.agents.refreshEnvironment).catch(() => undefined)
      const harness = (await run(config.agents.discoverHarnesses).catch(() => [])).find(
        (candidate) => candidate.id === harnessId
      )
      observedVersion = harness?.readiness.version
      if (observedVersion !== undefined && !isNewerVersion(targetVersion, observedVersion)) {
        return observedVersion
      }
      if (Date.now() >= deadline) {
        const observed = observedVersion === undefined ? "unknown" : observedVersion
        throw new Error(
          `Updater exited successfully, but ${harnessId} is still ${observed}; expected ${targetVersion}`
        )
      }
      await delay(updateVerificationPollIntervalMs)
    }
  }

  /// The local target probe is stronger than a second network lookup. Merge
  /// its observed version into the persisted/in-memory update knowledge so a
  /// failed feed refresh cannot resurrect the same Update button.
  const recordVerifiedInstalledVersion = async (
    harnessId: string,
    installedVersion: string
  ): Promise<void> => {
    const current = await loadStates()
    const previous = current.get(harnessId)
    if (previous === undefined) return
    const info: HarnessUpdateInfo = {
      ...previous,
      installedVersion,
      updateAvailable:
        previous.latestVersion !== undefined &&
        isNewerVersion(previous.latestVersion, installedVersion),
      checkedAt: new Date(now()).toISOString()
    }
    current.set(harnessId, info)
    await run(config.db.setHarnessUpdateState({ harnessId, info })).catch(() => undefined)
    if (meaningfullyChanged(previous, info)) {
      emit({
        kind: "harness.lifecycle.updated",
        payload: { harnessId, updateInfo: info },
        subjectId: harnessId
      })
    }
  }

  return {
    checkForUpdates,
    checkForUpdatesFresh,
    checkSource,
    recordVerifiedInstalledVersion,
    waitForInstalledTarget
  }
}

export type HarnessUpdateDetection = ReturnType<typeof makeHarnessUpdateDetection>
