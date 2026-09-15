/// Pure helpers for the Screen Sharing rig CLI: argument parsing, generated
/// files and command plans. Nothing here touches the filesystem, the network
/// or a process, so every rule is unit-testable.
import { rigIdentity } from "./screen-sharing-bundle.mjs"

export const rigLaunchAgentLabel = "com.codevisor.screen-sharing-rig"
export const rigInstallDirectory = "Applications/CodevisorRig" // relative to $HOME on each Mac
export const rigDefaultPort = 48731
export const rigDefaultControlPort = 48732

const xmlEscapes = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }
const escapeXML = (value) => String(value).replace(/[&<>"]/g, (c) => xmlEscapes[c])

/// A user LaunchAgent that owns exactly one rig process in the GUI session.
/// The viewer restarts only on abnormal exit: closing its window exits 0 and stays
/// down. The host has no window and restarts on any exit, including the clean one
/// macOS performs when a Screen Recording grant is applied with "Quit & Reopen".
export function launchAgentPlist({ home, configPath, logPath, role = "viewer" }) {
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
}) {
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
  const configuration = { role, token, port, controlPort, hud }
  if (role === "viewer") configuration.peer = peer
  if (role === "host" && capture !== undefined) configuration.capture = capture
  for (const [key, value] of Object.entries({ width, height, fps, bitrate, codec })) {
    if (value !== undefined) configuration[key] = value
  }
  return configuration
}

/// Commands to swap a freshly built bundle into place and restart the agent.
/// `remote` is an ssh target; when absent the plan runs locally. Returned as
/// argv arrays so nothing is shell-interpolated except the remote script.
export function deployPlan({ builtApp, home, uid, remote }) {
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

/// Commands to (re)load the LaunchAgent from its plist path. `bootout` returns while the
/// service is still unloading and a `bootstrap` issued then fails with EIO, so wait until
/// the service is gone (bounded) before loading it again.
export function bootstrapPlan({ uid, plistPath, remote }) {
  const service = `gui/${uid}/${rigLaunchAgentLabel}`
  const script = [
    `launchctl bootout ${service} >/dev/null 2>&1 || true`,
    `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do launchctl print ${service} >/dev/null 2>&1 || break; sleep 0.5; done`,
    `launchctl bootstrap gui/${uid} ${quote(plistPath)} && launchctl kickstart -k ${service}`
  ].join("; ")
  return remote ? [["ssh", remote, script]] : [["sh", "-c", script]]
}

export function stopPlan({ uid, remote }) {
  const script = `launchctl bootout gui/${uid}/${rigLaunchAgentLabel} >/dev/null 2>&1 || true`
  return remote ? [["ssh", remote, script]] : [["sh", "-c", script]]
}

export function quote(value) {
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
  "tune"
]

/// `rig <command> [--key value | --flag]...`. Unknown commands and dangling
/// values are errors; `build` is the default so the old invocation still works.
export function parseRigArguments(argv) {
  const [first, ...rest] = argv
  let command = "build"
  let remaining = argv
  if (first && !first.startsWith("-")) {
    if (!commands.includes(first))
      throw new Error(`Unknown command ${first}. Commands: ${commands.join(", ")}`)
    command = first
    remaining = rest
  }
  const options = {}
  const positional = []
  for (let index = 0; index < remaining.length; index += 1) {
    const argument = remaining[index]
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

export function buildInfoExtras({ commit, dirty, builtAt }) {
  return {
    CodevisorRigCommit: commit,
    CodevisorRigDirty: dirty ? "true" : "false",
    CodevisorRigBuiltAt: builtAt
  }
}

/// Parses `rig tune` arguments into the `tuning` object written to both configs: a JSON object,
/// `default` (remove all tuning), or the product profile name.
export function parseTuningArgument(argument) {
  if (argument === undefined)
    throw new Error("tune needs a JSON object, a profile name, or default")
  if (argument === "default") return null
  if (argument === "paced15-worker") return { profile: "paced15-worker" }
  let object
  try {
    object = JSON.parse(argument)
  } catch {
    throw new Error(`tune: not JSON, a profile name, or default: ${argument}`)
  }
  if (object === null || typeof object !== "object" || Array.isArray(object))
    throw new Error("tune: expected an object")
  return object
}

/// Returns a new configuration with `tuning` set (or removed when null).
export function withTuning(configuration, tuning) {
  const next = { ...configuration }
  if (tuning === null) delete next.tuning
  else next.tuning = tuning
  return next
}
