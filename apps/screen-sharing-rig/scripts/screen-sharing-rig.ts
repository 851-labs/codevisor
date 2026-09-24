#!/usr/bin/env node
// Screen Sharing rig CLI: build, install a host/viewer pair, deploy, inspect.
// See docs/plans/screen-sharing-rig.md. `bun run screen-sharing:rig --help`.
import { spawnSync } from "node:child_process"
import { randomBytes } from "node:crypto"
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import {
  designatedRequirement,
  diagnosticInfoPlist,
  parseCodesigningIdentities,
  resolveSigningIdentity,
  rigIdentity,
  signDiagnosticApp
} from "./screen-sharing-bundle.ts"
import {
  endpointsFor,
  http,
  summarize,
  type ControlCheckResult,
  type HudResult,
  type RigStatus,
  type SampleResult,
  type SourceResult
} from "./screen-sharing-rig-client.ts"
import {
  bootstrapPlan,
  buildInfoExtras,
  deployPlan,
  errorMessage,
  launchAgentPlist,
  parseRigArguments,
  quote,
  rigConfiguration,
  rigInstallDirectory,
  parseTuningArgument,
  rigLaunchAgentLabel,
  rigUsage as usage,
  stopPlan,
  stringOption,
  withTuning,
  type DeployRecord,
  type Plan,
  type RigCommand,
  type RigConfiguration
} from "./screen-sharing-rig-lib.ts"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
const packagePath = join(root, "apps/screen-sharing-rig")
const home = homedir()
const installDirectory = join(home, rigInstallDirectory)
const installedApp = join(installDirectory, rigIdentity.appName)
const localConfigPath = join(installDirectory, "rig.json")
const deployRecordPath = join(installDirectory, "deploy.json")
const plistPath = join(home, "Library/LaunchAgents", `${rigLaunchAgentLabel}.plist`)
const logDirectory = join(home, "Library/Logs/CodevisorRig")
const buildApp = join(root, "tmp/screen-sharing", rigIdentity.appName)

const { command, options, positional } = (() => {
  try {
    return parseRigArguments(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n\n${usage}`)
    process.exit(2)
  }
})()
if (options.help || options.h) {
  process.stdout.write(usage)
  process.exit(0)
}
if (process.platform !== "darwin") throw new Error("The Screen Sharing rig requires macOS.")

function localUid(): number {
  const uid = process.getuid?.()
  if (uid === undefined) throw new Error("Cannot read this Mac's uid.")
  return uid
}

function run(
  commandName: string,
  args: readonly string[],
  {
    capture = false,
    input,
    allowFailure = false
  }: { capture?: boolean; input?: string; allowFailure?: boolean } = {}
): string {
  const result = spawnSync(commandName, args, {
    cwd: root,
    stdio: [input === undefined ? "inherit" : "pipe", capture ? "pipe" : "inherit", "inherit"],
    ...(input === undefined ? {} : { input }),
    encoding: "utf8"
  })
  if (result.error) throw result.error
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`${commandName} ${args.map(String).join(" ")} exited ${result.status}`)
  }
  return result.stdout?.trim()
}
function runPlan(plan: Plan): void {
  for (const [commandName, ...args] of plan) run(commandName, args)
}

function readJSON<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T
}
function readLocalConfig(): RigConfiguration {
  if (!existsSync(localConfigPath))
    throw new Error(`No rig on this Mac yet: ${localConfigPath}. Run install first.`)
  return readJSON<RigConfiguration>(localConfigPath)
}
function readDeployRecord(): DeployRecord {
  if (!existsSync(deployRecordPath))
    throw new Error(`No deploy record: ${deployRecordPath}. Run install first.`)
  return readJSON<DeployRecord>(deployRecordPath)
}

// ---------------------------------------------------------------- build

async function build({ debug = false, install = true } = {}): Promise<string> {
  const configuration = debug ? "debug" : "release"
  const identities = parseCodesigningIdentities(
    run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], { capture: true })
  )
  const signing = resolveSigningIdentity({ env: process.env, identities })
  if (signing.warning) process.stderr.write(`${signing.warning}\n`)
  process.stdout.write(
    `Signing identity: ${signing.identity}${signing.source ? ` (${signing.source})` : ""}\n`
  )
  const commit =
    run("git", ["rev-parse", "HEAD"], { capture: true, allowFailure: true }) || "unknown"
  const dirty =
    run("git", ["status", "--porcelain", "--untracked-files=no"], {
      capture: true,
      allowFailure: true
    }) !== ""
  run("swift", [
    "build",
    "--package-path",
    packagePath,
    "--configuration",
    configuration,
    "--product",
    rigIdentity.executableName
  ])
  const bin = run(
    "swift",
    ["build", "--package-path", packagePath, "--configuration", configuration, "--show-bin-path"],
    {
      capture: true
    }
  )
  rmSync(buildApp, { recursive: true, force: true })
  const contents = join(buildApp, "Contents")
  const executable = join(contents, "MacOS", rigIdentity.executableName)
  const framework = join(contents, "Frameworks/WebRTC.framework")
  for (const directory of ["MacOS", "Frameworks", "Resources"])
    mkdirSync(join(contents, directory), { recursive: true })
  cpSync(join(bin, rigIdentity.executableName), executable)
  cpSync(join(bin, "WebRTC.framework"), framework, { recursive: true, verbatimSymlinks: true })
  cpSync(
    join(bin, "CodevisorKit_ScreenSharingWebRTC.bundle"),
    join(contents, "Resources/CodevisorKit_ScreenSharingWebRTC.bundle"),
    {
      recursive: true
    }
  )
  writeFileSync(
    join(contents, "Info.plist"),
    diagnosticInfoPlist({
      bundleIdentifier: rigIdentity.bundleIdentifier,
      displayName: rigIdentity.displayName,
      executableName: rigIdentity.executableName,
      configuration,
      extra: buildInfoExtras({ commit, dirty, builtAt: new Date().toISOString() })
    })
  )
  run("install_name_tool", ["-add_rpath", "@executable_path/../Frameworks", executable])
  await signDiagnosticApp({
    app: buildApp,
    frameworks: [framework],
    identity: signing.identity,
    run: (c, a) => run(c, a)
  })
  run("/usr/bin/codesign", ["--verify", "--deep", "--strict", buildApp])
  const requirement = await designatedRequirement({
    app: buildApp,
    capture: (c, a) => run(c, a, { capture: true })
  })
  process.stdout.write(
    `Built ${buildApp} (${commit.slice(0, 8)}${dirty ? "*" : ""} ${configuration})\nDesignated requirement: ${requirement}\n`
  )
  if (install) installLocally()
  return buildApp
}

function installLocally(): void {
  mkdirSync(installDirectory, { recursive: true })
  const staging = join(installDirectory, `.staging-${rigIdentity.appName}`)
  const previous = join(installDirectory, `.previous-${rigIdentity.appName}`)
  rmSync(staging, { recursive: true, force: true })
  cpSync(buildApp, staging, { recursive: true, verbatimSymlinks: true })
  rmSync(previous, { recursive: true, force: true })
  if (existsSync(installedApp)) renameSync(installedApp, previous)
  renameSync(staging, installedApp)
  rmSync(previous, { recursive: true, force: true })
  process.stdout.write(`Installed ${installedApp}\n`)
}

// ---------------------------------------------------------------- install / deploy

function remoteFacts(target: string): { remoteHome: string; remoteUid: number } {
  const [remoteHome, uid] = run("ssh", ["-o", "BatchMode=yes", target, 'echo "$HOME"; id -u'], {
    capture: true
  }).split("\n")
  if (!remoteHome || !uid) throw new Error(`Cannot read HOME/uid over ssh from ${target}`)
  return { remoteHome, remoteUid: Number(uid) }
}

function writeRemoteFile(target: string, path: string, content: string): void {
  run(
    "ssh",
    ["-o", "BatchMode=yes", target, `mkdir -p ${quote(dirname(path))} && cat > ${quote(path)}`],
    { input: content }
  )
}

async function install(): Promise<void> {
  const target = stringOption(options, "host")
  const hostAddress = stringOption(options, "host-address")
  if (!target || !hostAddress)
    throw new Error("install needs --host USER@SSHHOST and --host-address IP\n\n" + usage)
  const token = stringOption(options, "token") ?? randomBytes(24).toString("hex")
  const portOption = stringOption(options, "port")
  const port = portOption ? Number(portOption) : undefined
  const controlPortOption = stringOption(options, "control-port")
  const controlPort = controlPortOption ? Number(controlPortOption) : undefined
  const hud = !options["no-hud"]
  const viewer = rigConfiguration({
    role: "viewer",
    token,
    peer: hostAddress,
    port,
    controlPort,
    hud
  })
  const host = rigConfiguration({
    role: "host",
    token,
    port,
    controlPort,
    hud,
    capture: stringOption(options, "capture") ?? "synthetic"
  })
  const { remoteHome, remoteUid } = remoteFacts(target)
  const remoteInstall = `${remoteHome}/${rigInstallDirectory}`
  const remoteConfig = `${remoteInstall}/rig.json`
  const remotePlist = `${remoteHome}/Library/LaunchAgents/${rigLaunchAgentLabel}.plist`
  const remoteLog = `${remoteHome}/Library/Logs/CodevisorRig/rig.log`

  process.stdout.write(
    `Viewer: this Mac → host ${hostAddress}; host: ${target} (${remoteHome}, uid ${remoteUid}), capture ${host.capture}\n`
  )
  mkdirSync(installDirectory, { recursive: true })
  mkdirSync(logDirectory, { recursive: true })
  mkdirSync(dirname(plistPath), { recursive: true })
  writeFileSync(localConfigPath, JSON.stringify(viewer, null, 2) + "\n", { mode: 0o600 })
  writeFileSync(
    deployRecordPath,
    JSON.stringify({ hostSSH: target, hostAddress, remoteHome, remoteUid }, null, 2) + "\n"
  )
  writeFileSync(
    plistPath,
    launchAgentPlist({ home, configPath: localConfigPath, logPath: join(logDirectory, "rig.log") })
  )
  writeRemoteFile(target, remoteConfig, JSON.stringify(host, null, 2) + "\n")
  run("ssh", [
    "-o",
    "BatchMode=yes",
    target,
    `chmod 600 ${quote(remoteConfig)} && mkdir -p ${quote(dirname(remoteLog))}`
  ])
  writeRemoteFile(
    target,
    remotePlist,
    launchAgentPlist({
      home: remoteHome,
      configPath: remoteConfig,
      logPath: remoteLog,
      role: "host"
    })
  )

  await build({ debug: Boolean(options.debug), install: false })
  runPlan(deployPlan({ builtApp: buildApp, home, uid: localUid() }))
  runPlan(deployPlan({ builtApp: buildApp, home: remoteHome, uid: remoteUid, remote: target }))
  runPlan(bootstrapPlan({ uid: remoteUid, plistPath: remotePlist, remote: target }))
  runPlan(bootstrapPlan({ uid: localUid(), plistPath }))
  process.stdout.write(
    `Installed. Token is in ${localConfigPath} and ${target}:${remoteConfig}. Try: bun run screen-sharing:rig status\n`
  )
}

async function deploy(): Promise<void> {
  const record = readDeployRecord()
  await build({ debug: Boolean(options.debug), install: false })
  runPlan(deployPlan({ builtApp: buildApp, home, uid: localUid() }))
  runPlan(
    deployPlan({
      builtApp: buildApp,
      home: record.remoteHome,
      uid: record.remoteUid,
      remote: record.hostSSH
    })
  )
  process.stdout.write("Deployed to both Macs; agents restarted.\n")
}

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
      process.stdout.write(`${label.padEnd(6)} unreachable at ${base}: ${errorMessage(error)}\n`)
    }
  }
}

async function sample(): Promise<void> {
  const seconds = Number(stringOption(options, "seconds"))
  if (!Number.isInteger(seconds) || seconds < 1) throw new Error("sample needs --seconds N")
  const reportOption = stringOption(options, "report")
  const report = reportOption
    ? resolve(reportOption)
    : join(
        root,
        "tmp/screen-sharing/rig-samples",
        `${new Date().toISOString().replace(/[:.]/g, "-")}.json`
      )
  const { token, viewer } = endpoints()
  const result = await http<SampleResult>("POST", `${viewer}/sample`, token, { seconds, report })
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
  run("launchctl", ["kickstart", "-k", `gui/${localUid()}/${rigLaunchAgentLabel}`])
  process.stdout.write(
    `tuning ${tuning === null ? "removed" : JSON.stringify(tuning)}; both agents restarted.\n`
  )
}

async function controlCheck(): Promise<void> {
  const clicksOption = stringOption(options, "clicks")
  const keysOption = stringOption(options, "keys")
  const clicks = clicksOption === undefined ? 5 : Number(clicksOption)
  const keys = keysOption === undefined ? 0 : Number(keysOption)
  for (const [name, value] of [
    ["clicks", clicks],
    ["keys", keys]
  ] as const) {
    if (!Number.isInteger(value) || value < 0 || value > 100)
      throw new Error(`control-check needs --${name} 0...100`)
  }
  const { token, viewer } = endpoints()
  const result = await http<ControlCheckResult>("POST", `${viewer}/control-check`, token, {
    clicks,
    keys,
    x: 0.5,
    y: 0.5,
    seconds: 15
  })
  const expected = (result.clicksSent ?? 0) + (result.keysSent ?? 0)
  const delivered =
    result.responsesAfter !== undefined &&
    result.responsesBefore !== undefined &&
    result.responsesAfter - result.responsesBefore === expected
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
  const result = await http<SourceResult>("POST", `${host}/source`, token, { capture: spec })
  process.stdout.write(
    `host source ${result.previous} → ${result.capture}${result.live ? " (live)" : " (next session)"}\n`
  )
}

async function hud(): Promise<void> {
  const enabled = positional[0] === "on" ? true : positional[0] === "off" ? false : null
  if (enabled === null) throw new Error("hud needs on|off")
  const { token, viewer, host } = endpoints()
  const result = await http<HudResult>("POST", `${options.host ? host : viewer}/hud`, token, {
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
  runPlan(stopPlan({ uid: localUid() }))
  process.stdout.write("Local rig agent unloaded.\n")
  if (options.all) {
    const record = readDeployRecord()
    runPlan(stopPlan({ uid: record.remoteUid, remote: record.hostSSH }))
    process.stdout.write(`Host rig agent unloaded on ${record.hostSSH}.\n`)
  }
}

const handlers: Record<RigCommand, () => unknown> = {
  build: () =>
    build({
      debug: Boolean(options.debug),
      install: !(options["build-only"] || options["no-install"])
    }),
  install,
  deploy,
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
  process.stderr.write(`screen-sharing:rig ${command}: ${errorMessage(error)}\n`)
  process.exit(1)
}
