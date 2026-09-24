/// Shared assembly and signing rules for Screen Sharing diagnostic bundles.
/// Pure functions take an injectable `run` so tests never spawn codesign.

export const rigIdentity = Object.freeze({
  bundleIdentifier: "com.codevisor.ScreenSharingRig",
  displayName: "Codevisor Screen Sharing Rig",
  executableName: "screen-sharing-rig",
  appName: "ScreenSharingRig.app"
})

export const signingIdentityVariable = "CODEVISOR_RIG_SIGN_IDENTITY"

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

/// Parse `security find-identity -v -p codesigning` output. Lines that carry a
/// trailing status such as `(CSSMERR_TP_CERT_REVOKED)` are not usable.
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

/// Pick the rig's signing identity. Precedence: explicit environment override,
/// the first valid Apple Development identity, then ad-hoc with a warning.
/// Ad-hoc signing pins TCC grants to the code hash, which is the churn the rig
/// exists to remove, so it is never silent. Developer ID is deliberately not
/// selected automatically: the rig must not look like a shipping artifact.
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

/// Info.plist for a diagnostic bundle. Keys are emitted sorted so two builds of
/// the same inputs produce identical bytes.
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
    // Signaling is plain HTTP with a bearer token. ATS exempts RFC 1918 addresses on its own, but not
    // a Tailscale peer (100.64/10 or a MagicDNS name), which is how the two Macs reach each other off LAN.
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

/// Keys sorted, nested dictionaries rendered the same way.
function plistDict(entries: PlistDictionary): string {
  const body = Object.entries(entries)
    .toSorted(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, value]) => `<key>${escapeXML(key)}</key>${plistValue(value)}`)
    .join("\n")
  return `<dict>\n${body}\n</dict>`
}

export type CommandRunner = (command: string, args: string[]) => unknown
export type CommandCapture = (command: string, args: string[]) => string | Promise<string>

/// Sign nested code before the app, inside out, with one identity and no
/// timestamp server. Returns the commands issued so callers can log them.
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
}): Promise<string[][]> {
  if (!identity) throw new Error("A signing identity is required (use - for ad hoc).")
  const commands: string[][] = []
  const sign = async (path: string) => {
    const args = ["--force", "--sign", identity, "--timestamp=none", path]
    commands.push(["/usr/bin/codesign", ...args])
    await run("/usr/bin/codesign", args)
  }
  // Sequential on purpose: nested code must be sealed before the outer bundle.
  // oxlint-disable-next-line no-await-in-loop
  for (const framework of frameworks) await sign(framework)
  await sign(app)
  return commands
}

/// The designated requirement is what TCC pins a grant to. Read it back so a
/// build can prove it did not change from the previous build. An ad-hoc
/// signature has only an implicit cdhash requirement, which codesign prints
/// commented out (`# designated => cdhash H"…"`).
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
