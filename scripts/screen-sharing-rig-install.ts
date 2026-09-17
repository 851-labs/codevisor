// Getting the rig built and onto a machine: build + sign the app bundle, put it
// on this Mac, and push the pair (viewer here, host over ssh) into place.
// Split out of screen-sharing-rig.ts, which owns the CLI and the live commands.
import { randomBytes } from "node:crypto"
import { cpSync, existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

import {
  designatedRequirement,
  diagnosticInfoPlist,
  parseCodesigningIdentities,
  resolveSigningIdentity,
  rigIdentity,
  signDiagnosticApp
} from "./screen-sharing-bundle.ts"
import {
  bootstrapPlan,
  buildInfoExtras,
  deployPlan,
  launchAgentPlist,
  quote,
  rigConfiguration,
  rigInstallDirectory,
  rigLaunchAgentLabel
} from "./screen-sharing-rig-lib.ts"
import type { RigOptions } from "./screen-sharing-rig-lib.ts"
import {
  buildApp,
  deployRecordPath,
  home,
  installDirectory,
  installedApp,
  localConfigPath,
  logDirectory,
  packagePath,
  plistPath,
  readDeployRecord,
  run,
  runPlan,
  writeRemoteFile
} from "./screen-sharing-rig-shell.ts"

// ---------------------------------------------------------------- build

export interface BuildOptions {
  debug?: boolean
  install?: boolean
}

export function build({ debug = false, install = true }: BuildOptions = {}): Promise<string> {
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

export async function install(options: RigOptions, usage: string): Promise<void> {
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
  runPlan(deployPlan({ builtApp: buildApp, home, uid: process.getuid!() }))
  runPlan(deployPlan({ builtApp: buildApp, home: remoteHome, uid: remoteUid, remote: target }))
  runPlan(bootstrapPlan({ uid: remoteUid, plistPath: remotePlist, remote: target }))
  runPlan(bootstrapPlan({ uid: process.getuid!(), plistPath }))
  process.stdout.write(
    `Installed. Token is in ${localConfigPath} and ${target}:${remoteConfig}. Try: bun run screen-sharing:rig status\n`
  )
}

export async function deploy(options: RigOptions): Promise<void> {
  const record = readDeployRecord()
  await build({ debug: Boolean(options.debug), install: false })
  runPlan(deployPlan({ builtApp: buildApp, home, uid: process.getuid!() }))
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
