import { X509Certificate } from "node:crypto"

import type { CommandRunner } from "./commands.ts"

const adHocWarning =
  "This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild."

export async function resolveDevelopmentSigningArguments(
  capture: CommandRunner["capture"]
): Promise<Array<string>> {
  const identities = await capture("security", ["find-identity", "-v", "-p", "codesigning"])
  const match = identities.match(/[0-9]+\)\s+([0-9A-F]+)\s+"(Apple Development:[^"]+)"/)
  if (match === null) {
    console.warn(`\nNo Apple Development signing identity was found. ${adHocWarning}`)
    return []
  }

  const [, hash, identity] = match
  const certificate = await capture("security", ["find-certificate", "-c", identity ?? "", "-p"])
  const team = new X509Certificate(certificate).toLegacyObject().subject.OU
  if (typeof team !== "string" || team.length === 0) {
    console.warn(`\nThe ${identity} certificate has no signing team identifier. ${adHocWarning}`)
    return []
  }

  console.log(`Using stable development signing identity ${hash} (${team})`)
  return [
    `CODE_SIGN_IDENTITY=${hash}`,
    `DEVELOPMENT_TEAM=${team}`,
    "CODE_SIGN_STYLE=Manual",
    "PROVISIONING_PROFILE_SPECIFIER="
  ]
}
