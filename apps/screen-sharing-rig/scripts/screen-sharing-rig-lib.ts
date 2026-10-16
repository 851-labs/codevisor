import { isBoolean, isNumber, isRecord, isString, optional, shape } from "./json-shape.ts"
import { escapeXML, rigIdentity } from "./screen-sharing-bundle.ts"

export const rigLaunchAgentLabel = "com.codevisor.screen-sharing-rig"
export const rigInstallDirectory = "Applications/CodevisorRig"
export const rigDefaultPort = 48731
export const rigDefaultControlPort = 48732

export type RigRole = "host" | "viewer"

export type Tuning = Record<string, unknown>

export type RigConfiguration = {
  role: RigRole
  token: string
  port: number
  controlPort: number
  hud: boolean
  peer?: string
  capture?: string
  width?: number
  height?: number
  fps?: number
  bitrate?: number
  codec?: string
  tuning?: Tuning
}

export interface DeployRecord {
  hostSSH: string
  hostAddress: string
  remoteHome: string
  remoteUid: number
}

export const isRigConfiguration = shape<RigConfiguration>({
  role: (value) => value === "host" || value === "viewer",
  token: isString,
  port: isNumber,
  controlPort: isNumber,
  hud: isBoolean,
  peer: optional(isString),
  capture: optional(isString),
  width: optional(isNumber),
  height: optional(isNumber),
  fps: optional(isNumber),
  bitrate: optional(isNumber),
  codec: optional(isString),
  tuning: optional(isRecord)
})

export const isDeployRecord = shape<DeployRecord>({
  hostSSH: isString,
  hostAddress: isString,
  remoteHome: isString,
  remoteUid: isNumber
})

export type Command = [command: string, ...args: string[]]
export type Plan = Command[]

export function launchAgentPlist({
  home,
  configPath,
  logPath,
  role = "viewer"
}: {
  home: string
  configPath: string
  logPath: string
  role?: RigRole
}): string {
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
}: {
  role: RigRole
  token: string
  peer?: string | undefined
  port?: number | undefined
  controlPort?: number | undefined
  capture?: string | undefined
  hud?: boolean
  width?: number
  height?: number
  fps?: number
  bitrate?: number
  codec?: string
}): RigConfiguration {
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
  const configuration: RigConfiguration = { role, token, port, controlPort, hud }
  if (role === "viewer" && peer) configuration.peer = peer
  if (role === "host" && capture !== undefined) configuration.capture = capture
  if (width !== undefined) configuration.width = width
  if (height !== undefined) configuration.height = height
  if (fps !== undefined) configuration.fps = fps
  if (bitrate !== undefined) configuration.bitrate = bitrate
  if (codec !== undefined) configuration.codec = codec
  return configuration
}

export function deployPlan({
  builtApp,
  home,
  uid,
  remote
}: {
  builtApp: string
  home: string
  uid: number
  remote?: string
}): Plan {
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

export function bootstrapPlan({
  uid,
  plistPath,
  remote
}: {
  uid: number
  plistPath: string
  remote?: string
}): Plan {
  const service = `gui/${uid}/${rigLaunchAgentLabel}`
  const script = [
    `launchctl bootout ${service} >/dev/null 2>&1 || true`,
    `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do launchctl print ${service} >/dev/null 2>&1 || break; sleep 0.5; done`,
    `launchctl bootstrap gui/${uid} ${quote(plistPath)} && launchctl kickstart -k ${service}`
  ].join("; ")
  return remote ? [["ssh", remote, script]] : [["sh", "-c", script]]
}

export function stopPlan({ uid, remote }: { uid: number; remote?: string }): Plan {
  const script = `launchctl bootout gui/${uid}/${rigLaunchAgentLabel} >/dev/null 2>&1 || true`
  return remote ? [["ssh", remote, script]] : [["sh", "-c", script]]
}

export function quote(value: string | number): string {
  return `'${String(value).replace(/'/g, `'\\''`)}'`
}

const commands = [
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
] as const

export type RigCommand = (typeof commands)[number]
export type RigOptions = Record<string, string | true>

const isRigCommand = (value: string): value is RigCommand =>
  (commands as readonly string[]).includes(value)

export const rigUsage = `Usage: bun run screen-sharing:rig <command> [options]

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

export function parseRigArguments(argv: string[]): {
  command: RigCommand
  options: RigOptions
  positional: string[]
} {
  const [first, ...rest] = argv
  let command: RigCommand = "build"
  let remaining = argv
  if (first && !first.startsWith("-")) {
    if (!isRigCommand(first))
      throw new Error(`Unknown command ${first}. Commands: ${commands.join(", ")}`)
    command = first
    remaining = rest
  }
  const options: RigOptions = {}
  const positional: string[] = []
  const queue = [...remaining]
  for (let argument = queue.shift(); argument !== undefined; argument = queue.shift()) {
    if (!argument.startsWith("--")) {
      positional.push(argument)
      continue
    }
    const key = argument.slice(2)
    const next = queue[0]
    if (next !== undefined && !next.startsWith("--")) {
      options[key] = next
      queue.shift()
    } else {
      options[key] = true
    }
  }
  return { command, options, positional }
}

export function stringOption(options: RigOptions, key: string): string | undefined {
  const value = options[key]
  if (value === true) throw new Error(`--${key} needs a value`)
  return value
}

export function buildInfoExtras({
  commit,
  dirty,
  builtAt
}: {
  commit: string
  dirty: boolean
  builtAt: string
}): Record<string, string> {
  return {
    CodevisorRigCommit: commit,
    CodevisorRigDirty: dirty ? "true" : "false",
    CodevisorRigBuiltAt: builtAt
  }
}

export function parseTuningArgument(argument: string | undefined): Tuning | null {
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
  if (!isRecord(object)) throw new Error("tune: expected an object")
  return object
}

const topLevelTuningKeys = ["codec", "bitrate"]

export function withTuning(
  configuration: Readonly<Record<string, unknown>>,
  tuning: Tuning | null
): Record<string, unknown> {
  const next: Record<string, unknown> = { ...configuration }
  if (tuning === null) {
    delete next.tuning
    return next
  }
  const rest = { ...tuning }
  for (const key of topLevelTuningKeys) {
    if (!(key in rest)) continue
    next[key] = rest[key]
    delete rest[key]
  }
  if (Object.keys(rest).length === 0) delete next.tuning
  else next.tuning = rest
  return next
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
