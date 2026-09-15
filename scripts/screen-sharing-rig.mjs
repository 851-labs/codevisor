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
} from "./screen-sharing-bundle.mjs"
import {
  bootstrapPlan,
  buildInfoExtras,
  deployPlan,
  launchAgentPlist,
  parseRigArguments,
  quote,
  rigConfiguration,
  rigInstallDirectory,
  parseTuningArgument,
  rigLaunchAgentLabel,
  stopPlan,
  withTuning
} from "./screen-sharing-rig-lib.mjs"

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const packagePath = join(root, "packages/swift")
const home = homedir()
const installDirectory = join(home, rigInstallDirectory)
const installedApp = join(installDirectory, rigIdentity.appName)
const localConfigPath = join(installDirectory, "rig.json")
const deployRecordPath = join(installDirectory, "deploy.json")
const plistPath = join(home, "Library/LaunchAgents", `${rigLaunchAgentLabel}.plist`)
const logDirectory = join(home, "Library/Logs/CodevisorRig")
const buildApp = join(root, "tmp/screen-sharing", rigIdentity.appName)

const usage = `Usage: bun run screen-sharing:rig <command> [options]

  build   [--debug] [--build-only]      Build + sign tmp/screen-sharing/${rigIdentity.appName}; install locally unless --build-only
  install --host USER@SSHHOST --host-address IP [--capture SRC] [--token T] [--port N] [--control-port N] [--no-hud] [--debug]
                                        Configure this Mac as the viewer and SSHHOST as the host, build, deploy both, start both agents
  deploy  [--debug]                     Build, push to both Macs, restart both agents (the everyday loop)
  status                                Show both ends' connection, session and build
  stop    [--all]                       Unload the local agent (and the host's with --all)
  sample  --seconds N [--report PATH]   Ask the viewer for an N-second telemetry sample (HUD off during it)
  hud     on|off [--host]               Toggle the viewer (or host) overlay
  tune    JSON|paced15-worker|default   Write engine tuning into both configs and restart both agents (no rebuild)
  source  SPEC                          Switch the host's capture source live (synthetic, workload:WxH@fps, virtual:WxH@fps, virtual-desktop:WxH@fps, app:BUNDLE, window:ID, display:ID)
  logs                                  Tail both rig logs

Capture sources: synthetic (default), workload:WxH@fps (own window, no permission), virtual:WxH@fps (private CGVirtualDisplay with the workload window on it; needs Screen Recording), display:ID (needs Screen Recording).
`

const { command, options, positional } = (() => {
  try {
    return parseRigArguments(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`${error.message}\n\n${usage}`)
    process.exit(2)
  }
})()
if (options.help || options.h) {
  process.stdout.write(usage)
  process.exit(0)
}
if (process.platform !== "darwin") throw new Error("The Screen Sharing rig requires macOS.")

function run(commandName, args, { capture = false, input, allowFailure = false } = {}) {
  const result = spawnSync(commandName, args, {
    cwd: root,
    stdio: [input === undefined ? "inherit" : "pipe", capture ? "pipe" : "inherit", "inherit"],
    input,
    encoding: "utf8"
  })
  if (result.error) throw result.error
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`${commandName} ${args.map(String).join(" ")} exited ${result.status}`)
  }
  return result.stdout?.trim()
}
const runPlan = (plan) => plan.forEach(([commandName, ...args]) => run(commandName, args))

function readJSON(path) {
  return JSON.parse(readFileSync(path, "utf8"))
}
function readLocalConfig() {
  if (!existsSync(localConfigPath))
    throw new Error(`No rig on this Mac yet: ${localConfigPath}. Run install first.`)
  return readJSON(localConfigPath)
}
function readDeployRecord() {
  if (!existsSync(deployRecordPath))
    throw new Error(`No deploy record: ${deployRecordPath}. Run install first.`)
  return readJSON(deployRecordPath)
}

async function http(method, url, token, body) {
  const init = {
    method,
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(body?.seconds ? (body.seconds + 15) * 1000 : 5000)
  }
  if (body) {
    init.headers["Content-Type"] = "application/json"
    init.body = JSON.stringify(body)
  }
  const response = await fetch(url, init)
  const text = await response.text()
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = { error: text }
  }
  if (!response.ok)
    throw new Error(`${method} ${url} → ${response.status}: ${parsed.error ?? text}`)
  return parsed
}

// ---------------------------------------------------------------- build

function build({ debug = false, install = true } = {}) {
  const configuration = debug ? "debug" : "release"
  const identities = parseCodesigningIdentities(
    run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], { capture: true }) ?? ""
  )
  const signing = resolveSigningIdentity({ env: process.env, identities })
  if (signing.warning) process.stderr.write(`${signing.warning}\n`)
  process.stdout.write(
    `Signing identity: ${signing.identity}${signing.source ? ` (${signing.source})` : ""}\n`
  )
  const commit =
    run("git", ["rev-parse", "HEAD"], { capture: true, allowFailure: true }) || "unknown"
  const dirty =
    (run("git", ["status", "--porcelain", "--untracked-files=no"], {
      capture: true,
      allowFailure: true
    }) ?? "") !== ""
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
    join(bin, "CodevisorKit_CodevisorScreenSharing.bundle"),
    join(contents, "Resources/CodevisorKit_CodevisorScreenSharing.bundle"),
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
  return (async () => {
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
  })()
}

function installLocally() {
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

function remoteFacts(target) {
  const [remoteHome, uid] = run("ssh", ["-o", "BatchMode=yes", target, 'echo "$HOME"; id -u'], {
    capture: true
  }).split("\n")
  if (!remoteHome || !uid) throw new Error(`Cannot read HOME/uid over ssh from ${target}`)
  return { remoteHome, remoteUid: Number(uid) }
}

function writeRemoteFile(target, path, content) {
  run(
    "ssh",
    ["-o", "BatchMode=yes", target, `mkdir -p ${quote(dirname(path))} && cat > ${quote(path)}`],
    { input: content }
  )
}

async function install() {
  const target = options.host
  const hostAddress = options["host-address"]
  if (!target || !hostAddress)
    throw new Error("install needs --host USER@SSHHOST and --host-address IP\n\n" + usage)
  const token = options.token ?? randomBytes(24).toString("hex")
  const port = options.port ? Number(options.port) : undefined
  const controlPort = options["control-port"] ? Number(options["control-port"]) : undefined
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
    capture: options.capture ?? "synthetic"
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
  runPlan(deployPlan({ builtApp: buildApp, home, uid: process.getuid() }))
  runPlan(deployPlan({ builtApp: buildApp, home: remoteHome, uid: remoteUid, remote: target }))
  runPlan(bootstrapPlan({ uid: remoteUid, plistPath: remotePlist, remote: target }))
  runPlan(bootstrapPlan({ uid: process.getuid(), plistPath }))
  process.stdout.write(
    `Installed. Token is in ${localConfigPath} and ${target}:${remoteConfig}. Try: bun run screen-sharing:rig status\n`
  )
}

async function deploy() {
  const record = readDeployRecord()
  await build({ debug: Boolean(options.debug), install: false })
  runPlan(deployPlan({ builtApp: buildApp, home, uid: process.getuid() }))
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

function endpoints() {
  const config = readLocalConfig()
  if (config.role !== "viewer")
    throw new Error("This Mac's rig is not the viewer; status runs from the viewer.")
  return {
    token: config.token,
    viewer: `http://127.0.0.1:${config.controlPort ?? 48732}`,
    host: `http://${config.peer.includes(":") ? config.peer : `${config.peer}:${config.port ?? 48731}`}`
  }
}

function summarize(status) {
  const build = status.build
    ? `${status.build.commit.slice(0, 8)}${status.build.dirty ? "*" : ""} ${status.build.configuration}`
    : "?"
  return `${status.role.padEnd(6)} ${status.name} · ${build} · ${status.connection} · session ${status.sessionID ?? "-"} · reconnects ${status.reconnects} · up ${Math.round(status.uptimeSeconds)}s${status.capture ? ` · ${status.capture}` : ""}`
}

async function status() {
  const { token, viewer, host } = endpoints()
  for (const [label, base] of [
    ["viewer", viewer],
    ["host", host]
  ]) {
    try {
      // oxlint-disable-next-line no-await-in-loop -- sequential output is the point
      process.stdout.write(`${summarize(await http("GET", `${base}/status`, token))}\n`)
    } catch (error) {
      process.stdout.write(`${label.padEnd(6)} unreachable at ${base}: ${error.message}\n`)
    }
  }
}

async function sample() {
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
  const result = await http("POST", `${viewer}/sample`, token, { seconds, report })
  process.stdout.write(
    `${result.samples} samples, mean presented ${result.meanPresentedFramesPerSecond?.toFixed(1) ?? "-"} fps → ${result.report}\n`
  )
}

function tune() {
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
    ),
    tuning
  )
  writeRemoteFile(record.hostSSH, remoteConfig, JSON.stringify(remote, null, 2) + "\n")
  run("ssh", [
    "-o",
    "BatchMode=yes",
    record.hostSSH,
    `launchctl kickstart -k gui/${record.remoteUid}/${rigLaunchAgentLabel}`
  ])
  run("launchctl", ["kickstart", "-k", `gui/${process.getuid()}/${rigLaunchAgentLabel}`])
  process.stdout.write(
    `tuning ${tuning === null ? "removed" : JSON.stringify(tuning)}; both agents restarted.\n`
  )
}

async function source() {
  const spec = positional[0]
  if (!spec) throw new Error("source needs a capture spec, e.g. source app:com.apple.dt.Xcode")
  const { token, host } = endpoints()
  const result = await http("POST", `${host}/source`, token, { capture: spec })
  process.stdout.write(
    `host source ${result.previous} → ${result.capture}${result.live ? " (live)" : " (next session)"}\n`
  )
}

async function hud() {
  const enabled = positional[0] === "on" ? true : positional[0] === "off" ? false : null
  if (enabled === null) throw new Error("hud needs on|off")
  const { token, viewer, host } = endpoints()
  const result = await http("POST", `${options.host ? host : viewer}/hud`, token, { enabled })
  process.stdout.write(`${options.host ? "host" : "viewer"} HUD ${result.enabled ? "on" : "off"}\n`)
}

function logs() {
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

function stop() {
  runPlan(stopPlan({ uid: process.getuid() }))
  process.stdout.write("Local rig agent unloaded.\n")
  if (options.all) {
    const record = readDeployRecord()
    runPlan(stopPlan({ uid: record.remoteUid, remote: record.hostSSH }))
    process.stdout.write(`Host rig agent unloaded on ${record.hostSSH}.\n`)
  }
}

const handlers = {
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
  tune
}
try {
  await handlers[command]()
} catch (error) {
  process.stderr.write(`screen-sharing:rig ${command}: ${error.message}\n`)
  process.exit(1)
}
