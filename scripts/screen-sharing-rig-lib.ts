/// Pure helpers for the Screen Sharing rig CLI: argument parsing, generated
/// files and command plans. Nothing here touches the filesystem, the network
/// or a process, so every rule is unit-testable.
import { rigIdentity } from "./screen-sharing-bundle.ts"

export const rigLaunchAgentLabel = "com.codevisor.screen-sharing-rig"
export const rigInstallDirectory = "Applications/CodevisorRig" // relative to $HOME on each Mac
export const rigDefaultPort = 48731
export const rigDefaultControlPort = 48732

export type RigRole = "host" | "viewer"

/// Engine tuning exactly as `tune` accepts it: an arbitrary JSON object whose
/// keys the Swift parser, not this script, validates.
export type RigTuning = Record<string, unknown>

type RigConfigurationCommon = {
  token: string
  port?: number
  controlPort?: number
  hud?: boolean
  capture?: string
  width?: number
  height?: number
  fps?: number
  bitrate?: number
  codec?: string
  tuning?: RigTuning
}

/// Only a host carries a capture source, and only a viewer dials a peer.
export interface HostRigConfiguration extends RigConfigurationCommon {
  role: "host"
}

export interface ViewerRigConfiguration extends RigConfigurationCommon {
  role: "viewer"
  peer: string
}

/// rig.json for one Mac, discriminated by `role`.
export type RigConfiguration = HostRigConfiguration | ViewerRigConfiguration

/// The mutable form a configuration takes while it is assembled or amended: the
/// role is not yet pinned to one member of the union.
type RigConfigurationDraft = RigConfigurationCommon & {
  role: RigRole
  peer?: string | undefined
}

/// One argv array: the executable followed by its arguments.
export type RigCommandLine = [string, ...string[]]
export type RigPlan = RigCommandLine[]

const xmlEscapes: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }
// Only the four characters above can match, so the lookup always hits.
const escapeXML = (value: string) => String(value).replace(/[&<>"]/g, (c) => xmlEscapes[c]!)

export interface LaunchAgentPlistOptions {
  home: string
  configPath: string
  logPath: string
  role?: RigRole
}

/// A user LaunchAgent that owns exactly one rig process in the GUI session.
/// The viewer restarts only on abnormal exit: closing its window exits 0 and stays
/// down. The host has no window and restarts on any exit, including the clean one
/// macOS performs when a Screen Recording grant is applied with "Quit & Reopen".
export function launchAgentPlist({
  home,
  configPath,
  logPath,
  role = "viewer"
}: LaunchAgentPlistOptions): string {
  const executable = `${home}/${rigInstallDirectory}/${rigIdentity.appName}/Contents/MacOS/${rigIdentity.executableName}`
  const args = [executable, "--config", configPath]
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${rigLaunchAgentLabel}</string>
<key>ProgramArguments</key><array>
${args.map((a) => `<string>${escapeXML(a)}</string>`).join("\n")}
</array>
<key>RunAtLoad</key><true/>
${role === "host" ? "<key>KeepAlive</key><true/>" : "<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>"}
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>ProcessType</key><string>Interactive</string>
<key>ThrottleInterval</key><integer>2</integer>
<key>StandardOutPath</key><string>${escapeXML(logPath)}</string>
<key>StandardErrorPath</key><string>${escapeXML(logPath)}</string>
</dict></plist>
`
}

export interface RigConfigurationOptions {
  role: RigRole
  token: string
  peer?: string
  // `install` passes these straight through from the command line, so both may
  // be absent as well as omitted.
  port?: number | undefined
  controlPort?: number | undefined
  capture?: string
  hud?: boolean
  width?: number
  height?: number
  fps?: number
  bitrate?: number
  codec?: string
}

/// rig.json for one role. Validation mirrors the Swift parser's hard rules so
/// a bad value fails here instead of on the other Mac.
export function rigConfiguration({
  role,
  token,
  peer,
  port = rigDefaultPort,
  controlPort = rigDefaultControlPort,
  capture,
  hud = true,
  width,
  height,
  fps,
  bitrate,
  codec
}: RigConfigurationOptions): RigConfiguration {
  if (role !== "host" && role !== "viewer") throw new Error("role must be host or viewer")
  if (typeof token !== "string" || token.length < 16 || /\s/.test(token)) {
    throw new Error("token must be at least 16 characters without whitespace")
  }
  if (role === "viewer" && !peer)
    throw new Error("a viewer needs the host address (--host-address)")
  if (
    role === "host" &&
    capture !== undefined &&
    !/^(synthetic|workload:\d+x\d+@\d+|virtual:\d+x\d+@\d+|virtual-desktop:\d+x\d+@\d+|app:[A-Za-z0-9.-]+|window:\d+|display:\d+)$/.test(
      capture
    )
  ) {
    throw new Error("capture must be synthetic, workload:WxH@fps or display:ID")
  }
  const configuration: RigConfigurationDraft = { role, token, port, controlPort, hud }
  if (role === "viewer") configuration.peer = peer
  if (role === "host" && capture !== undefined) configuration.capture = capture
  // The knobs are copied across by name, which only a loose view of the draft allows.
  const knobs = configuration as Record<string, unknown>
  for (const [key, value] of Object.entries({ width, height, fps, bitrate, codec })) {
    if (value !== undefined) knobs[key] = value
  }
  // The branches above are what make the draft one member of the union or the other.
  return configuration as RigConfiguration
}

export interface DeployPlanOptions {
  builtApp: string
  home: string
  uid: number
  remote?: string
}

/// deploy.json on the viewer: how to reach the host and where its rig lives.
export interface RigDeployRecord {
  hostSSH: string
  hostAddress: string
  remoteHome: string
  remoteUid: number
}

/// Commands to swap a freshly built bundle into place and restart the agent.
/// `remote` is an ssh target; when absent the plan runs locally. Returned as
/// argv arrays so nothing is shell-interpolated except the remote script.
export function deployPlan({ builtApp, home, uid, remote }: DeployPlanOptions): RigPlan {
  const install = `${home}/${rigInstallDirectory}`
  const app = `${install}/${rigIdentity.appName}`
  const staging = `${install}/.staging-${rigIdentity.appName}`
  const previous = `${install}/.previous-${rigIdentity.appName}`
  const swap = [
    `rm -rf ${quote(previous)}`,
    `if [ -d ${quote(app)} ]; then mv ${quote(app)} ${quote(previous)}; fi`,
    `mv ${quote(staging)} ${quote(app)}`,
    `rm -rf ${quote(previous)}`,
    `codesign --verify --deep --strict ${quote(app)}`,
    `launchctl kickstart -k gui/${uid}/${rigLaunchAgentLabel} || echo "rig agent not loaded yet; run install"`
  ].join(" && ")
  if (remote) {
    return [
      ["ssh", remote, `mkdir -p ${quote(install)} && rm -rf ${quote(staging)}`],
      ["rsync", "-a", "--delete", `${builtApp}/`, `${remote}:${staging}/`],
      ["ssh", remote, swap]
    ]
  }
  return [
    ["mkdir", "-p", install],
    ["rm", "-rf", staging],
    ["cp", "-R", builtApp, staging],
    ["sh", "-c", swap]
  ]
}

export interface BootstrapPlanOptions {
  uid: number
  plistPath: string
  remote?: string
}

/// Commands to (re)load the LaunchAgent from its plist path. `bootout` returns while the
/// service is still unloading and a `bootstrap` issued then fails with EIO, so wait until
/// the service is gone (bounded) before loading it again.
export function bootstrapPlan({ uid, plistPath, remote }: BootstrapPlanOptions): RigPlan {
  const service = `gui/${uid}/${rigLaunchAgentLabel}`
  const script = [
    `launchctl bootout ${service} >/dev/null 2>&1 || true`,
    `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do launchctl print ${service} >/dev/null 2>&1 || break; sleep 0.5; done`,
    `launchctl bootstrap gui/${uid} ${quote(plistPath)} && launchctl kickstart -k ${service}`
  ].join("; ")
  return remote ? [["ssh", remote, script]] : [["sh", "-c", script]]
}

export interface StopPlanOptions {
  uid: number
  remote?: string
}

export function stopPlan({ uid, remote }: StopPlanOptions): RigPlan {
  const script = `launchctl bootout gui/${uid}/${rigLaunchAgentLabel} >/dev/null 2>&1 || true`
  return remote ? [["ssh", remote, script]] : [["sh", "-c", script]]
}

export function quote(value: string): string {
  return `'${String(value).replace(/'/g, `'\\''`)}'`
}

export type RigCommandName =
  | "build"
  | "install"
  | "deploy"
  | "status"
  | "stop"
  | "sample"
  | "hud"
  | "logs"
  | "source"
  | "tune"
  | "control-check"

const commands: readonly string[] = [
  "build",
  "install",
  "deploy",
  "status",
  "stop",
  "sample",
  "hud",
  "logs",
  "source",
  "tune",
  "control-check"
]

/// `rig <command> [--key value | --flag]...`. Unknown commands and dangling
/// values are errors; `build` is the default so the old invocation still works.
/// Every `--flag` the commands read. The parser accepts any flag, so the value
/// types record what each command expects: a flag given a value arrives as a
/// string and a bare flag as `true` (`hud --host` is the one deliberate bare use
/// of a named option).
export interface RigOptions {
  [key: string]: string | true | undefined
  all?: true
  "build-only"?: true
  capture?: string
  clicks?: string
  "control-port"?: string
  debug?: true
  h?: true
  help?: true
  host?: string
  "host-address"?: string
  keys?: string
  "no-hud"?: true
  "no-install"?: true
  port?: string
  report?: string
  seconds?: string
  token?: string
}

export interface RigArguments {
  command: RigCommandName
  options: RigOptions
  positional: string[]
}

const isRigCommand = (value: string): value is RigCommandName => commands.includes(value)

export function parseRigArguments(argv: readonly string[]): RigArguments {
  const [first, ...rest] = argv
  let command: RigCommandName = "build"
  let remaining = argv
  if (first && !first.startsWith("-")) {
    if (!isRigCommand(first))
      throw new Error(`Unknown command ${first}. Commands: ${commands.join(", ")}`)
    command = first
    remaining = rest
  }
  const options: RigOptions = {}
  const positional: string[] = []
  for (let index = 0; index < remaining.length; index += 1) {
    // The loop is bounded by the length, so the argument is always there.
    const argument = remaining[index]!
    if (!argument.startsWith("--")) {
      positional.push(argument)
      continue
    }
    const key = argument.slice(2)
    const next = remaining[index + 1]
    if (next !== undefined && !next.startsWith("--")) {
      options[key] = next
      index += 1
    } else {
      options[key] = true
    }
  }
  return { command, options, positional }
}

export interface BuildInfoExtrasOptions {
  commit: string
  dirty: boolean
  builtAt: string
}

/// The Info.plist keys the rig's Swift `RigBuildInfo(infoDictionary:)` reads back.
export function buildInfoExtras({
  commit,
  dirty,
  builtAt
}: BuildInfoExtrasOptions): Record<string, string> {
  return {
    CodevisorRigCommit: commit,
    CodevisorRigDirty: dirty ? "true" : "false",
    CodevisorRigBuiltAt: builtAt
  }
}

/// Parses `rig tune` arguments into the `tuning` object written to both configs: a JSON object,
/// `default` (remove all tuning), or the product profile name.
export function parseTuningArgument(argument: string | undefined): RigTuning | null {
  if (argument === undefined)
    throw new Error("tune needs a JSON object, a profile name, or default")
  if (argument === "default") return null
  if (argument === "paced15-worker") return { profile: "paced15-worker" }
  let object: unknown
  try {
    object = JSON.parse(argument)
  } catch {
    throw new Error(`tune: not JSON, a profile name, or default: ${argument}`)
  }
  if (object === null || typeof object !== "object" || Array.isArray(object))
    throw new Error("tune: expected an object")
  // Anything the `tune` caller typed is legal JSON here; the rig validates it.
  return object as RigTuning
}

/// Keys a `tune` object may carry that live at the top of rig.json rather than under `tuning`.
const topLevelTuningKeys = ["codec", "bitrate"] as const

/// Returns a new configuration with `tuning` set (or removed when null). `codec` and `bitrate` in the
/// object move to the top level so one `tune` call can switch the codec with its knobs; `default` keeps them.
export function withTuning(
  configuration: RigConfiguration,
  tuning: RigTuning | null
): RigConfiguration {
  const next: RigConfigurationDraft = { ...configuration }
  if (tuning === null) {
    delete next.tuning
    return next as RigConfiguration
  }
  const rest = { ...tuning }
  // `tune` values are unchecked JSON, so they move across a loose view of the draft.
  const top = next as Record<string, unknown>
  for (const key of topLevelTuningKeys) {
    if (!(key in rest)) continue
    top[key] = rest[key]
    delete rest[key]
  }
  if (Object.keys(rest).length === 0) delete next.tuning
  else next.tuning = rest
  // `configuration` arrived as one member of the union and keeps its role.
  return next as RigConfiguration
}
