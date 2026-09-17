#!/usr/bin/env node
// Screen Sharing rig CLI: build, install a host/viewer pair, deploy, inspect.
// See docs/plans/screen-sharing-rig.md. `bun run screen-sharing:rig --help`.
// Building and deploying live in screen-sharing-rig-install.ts; this file owns
// the command line and everything that talks to an already-running rig.
import { writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

import { rigIdentity } from "./screen-sharing-bundle.ts"
import { endpointsFor, http, summarize } from "./screen-sharing-rig-client.ts"
import type {
  RigControlCheckResponse,
  RigHUDResponse,
  RigSampleResponse,
  RigSourceResponse,
  RigStatus
} from "./screen-sharing-rig-client.ts"
import { build, deploy, install } from "./screen-sharing-rig-install.ts"
import {
  parseRigArguments,
  parseTuningArgument,
  quote,
  rigInstallDirectory,
  rigLaunchAgentLabel,
  stopPlan,
  withTuning
} from "./screen-sharing-rig-lib.ts"
import type { RigCommandName, RigConfiguration } from "./screen-sharing-rig-lib.ts"
import {
  localConfigPath,
  logDirectory,
  readDeployRecord,
  readLocalConfig,
  root,
  run,
  runPlan,
  writeRemoteFile
} from "./screen-sharing-rig-shell.ts"

const usage = `Usage: bun run screen-sharing:rig <command> [options]

  build   [--debug] [--build-only]      Build + sign tmp/screen-sharing/${rigIdentity.appName}; install locally unless --build-only
  install --host USER@SSHHOST --host-address IP [--capture SRC] [--token T] [--port N] [--control-port N] [--no-hud] [--debug]
                                        Configure this Mac as the viewer and SSHHOST as the host, build, deploy both, start both agents
  deploy  [--debug]                     Build, push to both Macs, restart both agents (the everyday loop)
  status                                Show both ends' connection, session and build
  stop    [--all]                       Unload the local agent (and the host's with --all)
  sample  --seconds N [--report PATH]   Ask the viewer for an N-second telemetry sample (HUD off during it)
  hud     on|off [--host]               Toggle the viewer (or host) overlay
  tune    JSON|paced15-worker|default   Write engine tuning (and codec/bitrate) into both configs; restarts both agents
  control-check [--clicks N] [--keys M] Ask for control, click the host's workload N times (default 5) and press space M times, release; verifies delivery
  source  SPEC                          Switch the host's capture source live (synthetic, workload:WxH@fps, virtual:WxH@fps, virtual-desktop:WxH@fps, app:BUNDLE, window:ID, display:ID)
  logs                                  Tail both rig logs

Capture sources: synthetic (default), workload:WxH@fps (own window, no permission), virtual:WxH@fps (private CGVirtualDisplay with the workload window on it; needs Screen Recording), display:ID (needs Screen Recording).
`

const { command, options, positional } = (() => {
  try {
    return parseRigArguments(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`${(error as Error).message}\n\n${usage}`)
    process.exit(2)
  }
})()
if (options.help || options.h) {
  process.stdout.write(usage)
  process.exit(0)
}
if (process.platform !== "darwin") throw new Error("The Screen Sharing rig requires macOS.")

// ---------------------------------------------------------------- inspect / control

const endpoints = () => endpointsFor(readLocalConfig())

async function status(): Promise<void> {
  const { token, viewer, host } = endpoints()
  for (const [label, base] of [
    ["viewer", viewer],
    ["host", host]
  ] as const) {
    try {
      // oxlint-disable-next-line no-await-in-loop -- sequential output is the point
      process.stdout.write(`${summarize(await http<RigStatus>("GET", `${base}/status`, token))}\n`)
    } catch (error) {
      const message = (error as Error).message
      process.stdout.write(`${label.padEnd(6)} unreachable at ${base}: ${message}\n`)
    }
  }
}

async function sample(): Promise<void> {
  const seconds = Number(options.seconds)
  if (!Number.isInteger(seconds) || seconds < 1) throw new Error("sample needs --seconds N")
  const report = options.report
    ? resolve(options.report)
    : join(
        root,
        "tmp/screen-sharing/rig-samples",
        `${new Date().toISOString().replace(/[:.]/g, "-")}.json`
      )
  const { token, viewer } = endpoints()
  const result = await http<RigSampleResponse>("POST", `${viewer}/sample`, token, {
    seconds,
    report
  })
  process.stdout.write(
    `${result.samples} samples, mean presented ${result.meanPresentedFramesPerSecond?.toFixed(1) ?? "-"} fps → ${result.report}\n`
  )
}

function tune(): void {
  const tuning = parseTuningArgument(positional[0])
  const record = readDeployRecord()
  const local = withTuning(readLocalConfig(), tuning)
  writeFileSync(localConfigPath, JSON.stringify(local, null, 2) + "\n", { mode: 0o600 })
  const remoteConfig = `${record.remoteHome}/${rigInstallDirectory}/rig.json`
  const remote = withTuning(
    // The host's rig.json, written by this same script.
    JSON.parse(
      run("ssh", ["-o", "BatchMode=yes", record.hostSSH, `cat ${quote(remoteConfig)}`], {
        capture: true
      })
    ) as RigConfiguration,
    tuning
  )
  writeRemoteFile(record.hostSSH, remoteConfig, JSON.stringify(remote, null, 2) + "\n")
  run("ssh", [
    "-o",
    "BatchMode=yes",
    record.hostSSH,
    `launchctl kickstart -k gui/${record.remoteUid}/${rigLaunchAgentLabel}`
  ])
  run("launchctl", ["kickstart", "-k", `gui/${process.getuid!()}/${rigLaunchAgentLabel}`])
  process.stdout.write(
    `tuning ${tuning === null ? "removed" : JSON.stringify(tuning)}; both agents restarted.\n`
  )
}

async function controlCheck(): Promise<void> {
  const clicks = options.clicks === undefined ? 5 : Number(options.clicks)
  const keys = options.keys === undefined ? 0 : Number(options.keys)
  for (const [name, value] of [
    ["clicks", clicks],
    ["keys", keys]
  ] as const) {
    if (!Number.isInteger(value) || value < 0 || value > 100)
      throw new Error(`control-check needs --${name} 0...100`)
  }
  const { token, viewer } = endpoints()
  const result = await http<RigControlCheckResponse>("POST", `${viewer}/control-check`, token, {
    clicks,
    keys,
    x: 0.5,
    y: 0.5,
    seconds: 15
  })
  const expected = (result.clicksSent ?? 0) + (result.keysSent ?? 0)
  // Both counts are missing when control was denied; the NaN that leaves reads as undelivered.
  const responseDelta = result.responsesAfter! - result.responsesBefore!
  const delivered = responseDelta === expected
  const outcome = result.granted
    ? `granted · ${result.clicksSent} clicks · ${result.keysSent ?? 0} keys · host responses ${result.responsesBefore ?? "?"} → ${result.responsesAfter ?? "?"} · ${delivered ? "DELIVERED" : "NOT delivered"} · released: ${result.revokedReason ?? "no revoke seen"}`
    : `denied: ${result.deniedReason}`
  process.stdout.write(`control check: ${outcome}\n`)
  if (!result.granted || !delivered) process.exitCode = 1
}

async function source(): Promise<void> {
  const spec = positional[0]
  if (!spec) throw new Error("source needs a capture spec, e.g. source app:com.apple.dt.Xcode")
  const { token, host } = endpoints()
  const result = await http<RigSourceResponse>("POST", `${host}/source`, token, { capture: spec })
  process.stdout.write(
    `host source ${result.previous} → ${result.capture}${result.live ? " (live)" : " (next session)"}\n`
  )
}

async function hud(): Promise<void> {
  const enabled = positional[0] === "on" ? true : positional[0] === "off" ? false : null
  if (enabled === null) throw new Error("hud needs on|off")
  const { token, viewer, host } = endpoints()
  const result = await http<RigHUDResponse>("POST", `${options.host ? host : viewer}/hud`, token, {
    enabled
  })
  process.stdout.write(`${options.host ? "host" : "viewer"} HUD ${result.enabled ? "on" : "off"}\n`)
}

function logs(): void {
  const record = readDeployRecord()
  process.stdout.write("--- viewer (this Mac) ---\n")
  run("tail", ["-n", "20", join(logDirectory, "rig.log")], { allowFailure: true })
  process.stdout.write(`--- host (${record.hostSSH}) ---\n`)
  run(
    "ssh",
    [
      "-o",
      "BatchMode=yes",
      record.hostSSH,
      `tail -n 20 ${quote(`${record.remoteHome}/Library/Logs/CodevisorRig/rig.log`)}`
    ],
    {
      allowFailure: true
    }
  )
}

function stop(): void {
  runPlan(stopPlan({ uid: process.getuid!() }))
  process.stdout.write("Local rig agent unloaded.\n")
  if (options.all) {
    const record = readDeployRecord()
    runPlan(stopPlan({ uid: record.remoteUid, remote: record.hostSSH }))
    process.stdout.write(`Host rig agent unloaded on ${record.hostSSH}.\n`)
  }
}

const handlers: Record<RigCommandName, () => unknown> = {
  build: () =>
    build({
      debug: Boolean(options.debug),
      install: !(options["build-only"] || options["no-install"])
    }),
  install: () => install(options, usage),
  deploy: () => deploy(options),
  status,
  stop,
  sample,
  hud,
  logs,
  source,
  tune,
  "control-check": controlCheck
}
try {
  await handlers[command]()
} catch (error) {
  process.stderr.write(`screen-sharing:rig ${command}: ${(error as Error).message}\n`)
  process.exit(1)
}
