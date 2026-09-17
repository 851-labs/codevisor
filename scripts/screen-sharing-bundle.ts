/// Shared assembly and signing rules for Screen Sharing diagnostic bundles.
/// Pure functions take an injectable `run` so tests never spawn codesign.

export const rigIdentity = Object.freeze({
  bundleIdentifier: "com.codevisor.ScreenSharingRig",
  displayName: "Codevisor Screen Sharing Rig",
  executableName: "screen-sharing-rig",
  appName: "ScreenSharingRig.app"
})

export const signingIdentityVariable = "CODEVISOR_RIG_SIGN_IDENTITY"

/// One row of `security find-identity`.
export interface CodesigningIdentity {
  hash: string
  name: string
  valid: boolean
}

export interface SigningIdentityOptions {
  env?: Record<string, string | undefined>
  identities?: readonly CodesigningIdentity[]
}

export interface ResolvedSigningIdentity {
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
    // The hash and name groups are not optional in the pattern above.
    identities.push({ hash: match[1]!, name: match[2]!, valid: match[3] === undefined })
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
}: SigningIdentityOptions): ResolvedSigningIdentity {
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
  // Only the four characters above can match, so the lookup always hits.
  return String(value).replace(/[&<>"]/g, (character) => xmlEscapes[character]!)
}

export interface DiagnosticInfoPlistOptions {
  bundleIdentifier: string
  displayName: string
  executableName: string
  configuration: string
  extra?: Readonly<Record<string, string | boolean>>
}

/// Info.plist for a diagnostic bundle. Keys are emitted sorted so two builds of
/// the same inputs produce identical bytes.
export function diagnosticInfoPlist({
  bundleIdentifier,
  displayName,
  executableName,
  configuration,
  extra = {}
}: DiagnosticInfoPlistOptions): string {
  const entries: Record<string, string | boolean> = {
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
    ...extra
  }
  const body = Object.keys(entries)
    .toSorted()
    .map((key) => {
      // The keys come from `entries` itself, so every lookup hits.
      const value = entries[key]!
      const rendered =
        typeof value === "boolean"
          ? value
            ? "<true/>"
            : "<false/>"
          : `<string>${escapeXML(value)}</string>`
      return `<key>${escapeXML(key)}</key>${rendered}`
    })
    .join("\n")
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
${body}
</dict></plist>
`
}

/// Runs a command for its effect; the rig CLI passes its own `run`.
export type DiagnosticRun = (command: string, args: string[]) => unknown

/// Runs a command and resolves to its standard output.
export type DiagnosticCapture = (command: string, args: string[]) => Promise<string> | string

export interface SignDiagnosticAppOptions {
  app: string
  frameworks: readonly string[]
  identity: string
  run: DiagnosticRun
}

export interface DesignatedRequirementOptions {
  app: string
  capture: DiagnosticCapture
}

/// Sign nested code before the app, inside out, with one identity and no
/// timestamp server. Returns the commands issued so callers can log them.
export async function signDiagnosticApp({
  app,
  frameworks,
  identity,
  run
}: SignDiagnosticAppOptions): Promise<string[][]> {
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
/// build can prove it did not change from the previous build.
export async function designatedRequirement({
  app,
  capture
}: DesignatedRequirementOptions): Promise<string> {
  const output = await capture("/usr/bin/codesign", ["-d", "-r-", app])
  const line = output
    .split("\n")
    .map((entry) => entry.trim())
    .find((entry) => entry.startsWith("designated => "))
  if (!line) throw new Error(`codesign did not report a designated requirement for ${app}`)
  return line.slice("designated => ".length)
}
