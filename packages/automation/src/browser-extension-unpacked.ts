import { readFileSync } from "node:fs"
import { isAbsolute, join } from "node:path"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import { optionalString, recordOrEmpty } from "./unknown-values.js"

export const hasUnpackedInstall = (profiles: ReadonlyArray<string>): boolean =>
  profiles.some((profile) => unpackedInstallPaths(profile).length > 0)

const PREFERENCE_FILES = ["Preferences", "Secure Preferences"]

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
