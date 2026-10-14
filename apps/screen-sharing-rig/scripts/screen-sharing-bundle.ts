export const rigIdentity = Object.freeze({
  bundleIdentifier: "com.codevisor.ScreenSharingRig",
  displayName: "Codevisor Screen Sharing Rig",
  executableName: "screen-sharing-rig",
  appName: "ScreenSharingRig.app"
})

const signingIdentityVariable = "CODEVISOR_RIG_SIGN_IDENTITY"

export interface CodesigningIdentity {
  hash: string
  name: string
  valid: boolean
}

export interface SigningChoice {
  identity: string
  adHoc: boolean
  source?: "environment" | "keychain"
  warning?: string
}

export function parseCodesigningIdentities(text: string): CodesigningIdentity[] {
  const identities: CodesigningIdentity[] = []
  for (const line of text.split("\n")) {
    const match = /^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"(?:\s+\((\w+)\))?\s*$/.exec(line)
    if (!match) continue
    const [, hash = "", name = "", status] = match
    identities.push({ hash, name, valid: status === undefined })
  }
  return identities
}

export function resolveSigningIdentity({
  env = {},
  identities = []
}: {
  env?: Record<string, string | undefined>
  identities?: CodesigningIdentity[]
}): SigningChoice {
  const override = env[signingIdentityVariable]?.trim()
  if (override) {
    if (override === "-") {
      return {
        identity: "-",
        adHoc: true,
        warning: adHocWarning("requested through the environment")
      }
    }
    const known = identities.find((entry) => entry.name === override || entry.hash === override)
    if (known && !known.valid) {
      throw new Error(`${signingIdentityVariable} names an identity that is not valid: ${override}`)
    }
    return { identity: override, adHoc: false, source: "environment" }
  }
  const development = identities.find(
    (entry) => entry.valid && entry.name.startsWith("Apple Development:")
  )
  if (development) return { identity: development.name, adHoc: false, source: "keychain" }
  return {
    identity: "-",
    adHoc: true,
    warning: adHocWarning("no Apple Development identity found")
  }
}

function adHocWarning(reason: string): string {
  return `WARNING: signing ad hoc (${reason}). Screen Recording and Accessibility grants will be tied to this build's code hash and lost on the next rebuild. Set ${signingIdentityVariable} or add an Apple Development certificate to the login keychain.`
}

const xmlEscapes: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }
function escapeXML(value: string): string {
  return value.replace(/[&<>"]/g, (character) => xmlEscapes[character] ?? character)
}

export type PlistValue = string | boolean | PlistDictionary
export interface PlistDictionary {
  [key: string]: PlistValue
}

export function diagnosticInfoPlist({
  bundleIdentifier,
  displayName,
  executableName,
  configuration,
  extra = {}
}: {
  bundleIdentifier: string
  displayName: string
  executableName: string
  configuration: string
  extra?: PlistDictionary
}): string {
  const entries: PlistDictionary = {
    CFBundleIdentifier: bundleIdentifier,
    CFBundleName: displayName,
    CFBundleDisplayName: displayName,
    CFBundleExecutable: executableName,
    CFBundlePackageType: "APPL",
    CFBundleVersion: "1",
    CodevisorProbeBuildConfiguration: configuration,
    LSMinimumSystemVersion: "26.0",
    NSHighResolutionCapable: true,
    NSScreenCaptureUsageDescription:
      "Capture the display you select for a native Screen Sharing diagnostic.",
    NSLocalNetworkUsageDescription: "Connect to the other Mac in your Screen Sharing diagnostic.",
    NSAppTransportSecurity: { NSAllowsArbitraryLoads: true },
    ...extra
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">${plistDict(entries)}</plist>
`
}

function plistValue(value: PlistValue): string {
  if (typeof value === "boolean") return value ? "<true/>" : "<false/>"
  if (typeof value === "object") return plistDict(value)
  return `<string>${escapeXML(value)}</string>`
}

function plistDict(entries: PlistDictionary): string {
  const body = Object.entries(entries)
    .toSorted(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, value]) => `<key>${escapeXML(key)}</key>${plistValue(value)}`)
    .join("\n")
  return `<dict>\n${body}\n</dict>`
}

export type CommandRunner = (command: string, args: string[]) => unknown
export type CommandCapture = (command: string, args: string[]) => string | Promise<string>

export async function signDiagnosticApp({
  app,
  frameworks,
  identity,
  run
}: {
  app: string
  frameworks: string[]
  identity: string
  run: CommandRunner
}): Promise<void> {
  if (!identity) throw new Error("A signing identity is required (use - for ad hoc).")
  for (const path of [...frameworks, app]) {
    await run("/usr/bin/codesign", ["--force", "--sign", identity, "--timestamp=none", path])
  }
}

export async function designatedRequirement({
  app,
  capture
}: {
  app: string
  capture: CommandCapture
}): Promise<string> {
  const output = await capture("/usr/bin/codesign", ["-d", "-r-", app])
  const line = output
    .split("\n")
    .map((entry) => entry.trim().replace(/^#\s*/, ""))
    .find((entry) => entry.startsWith("designated => "))
  if (!line) throw new Error(`codesign did not report a designated requirement for ${app}`)
  return line.slice("designated => ".length)
}
