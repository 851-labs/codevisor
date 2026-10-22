import { existsSync, readFileSync, readdirSync } from "node:fs"
import { isAbsolute, join } from "node:path"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import { optionalString, recordOrEmpty } from "./unknown-values.js"

export const LEGACY_EXTENSION_RELAY_PORT = 49361

export interface ExtensionUpdateInputs {
  readonly connected: boolean
  readonly relayBaseUrl: string
  readonly profiles: ReadonlyArray<string>
}

export const extensionNeedsUpdate = (inputs: ExtensionUpdateInputs): boolean =>
  !inputs.connected &&
  servesOffLegacyPort(inputs.relayBaseUrl) &&
  inputs.profiles.some(installLacksPortScan)

const PORT_SCAN_MARKER = "relay-candidates.js"
const PREFERENCE_FILES = ["Preferences", "Secure Preferences"]

const servesOffLegacyPort = (relayBaseUrl: string): boolean =>
  Number(new URL(relayBaseUrl).port) !== LEGACY_EXTENSION_RELAY_PORT

const installLacksPortScan = (profile: string): boolean => {
  const copies = [...storeInstallVersions(profile), ...unpackedInstallPaths(profile)]
  if (copies.length === 0) return false
  return !copies.some((copy) => existsSync(join(copy, PORT_SCAN_MARKER)))
}

const storeInstallVersions = (profile: string): ReadonlyArray<string> => {
  const root = join(profile, "Extensions", CODEVISOR_BROWSER_EXTENSION_ID)
  try {
    return readdirSync(root).map((version) => join(root, version))
  } catch {
    return []
  }
}

const unpackedInstallPaths = (profile: string): ReadonlyArray<string> =>
  PREFERENCE_FILES.map((file) => installPath(join(profile, file))).filter(
    (path): path is string => path !== undefined && isAbsolute(path)
  )

const installPath = (preferencesFile: string): string | undefined => {
  try {
    const preferences: unknown = JSON.parse(readFileSync(preferencesFile, "utf8"))
    const settings = recordOrEmpty(recordOrEmpty(recordOrEmpty(preferences).extensions).settings)
    return optionalString(recordOrEmpty(settings[CODEVISOR_BROWSER_EXTENSION_ID]).path)
  } catch {
    return undefined
  }
}
