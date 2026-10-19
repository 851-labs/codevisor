import { readFile } from "node:fs/promises"
import { isAbsolute, resolve } from "node:path"

import { providerOAuthSupported, type ProviderOAuthHarness } from "@codevisor/harness-manager"

import { errorCode, isRecord } from "../unknown-values.js"

export const readProviderDocument = async (path: string): Promise<Record<string, unknown>> => {
  try {
    const value: unknown = JSON.parse(await readFile(path, "utf8"))
    if (!isRecord(value)) throw new Error("Invalid credential file")
    return { ...value }
  } catch (cause) {
    if (errorCode(cause) === "ENOENT") return {}
    throw new Error("Saved provider credentials could not be read", { cause })
  }
}

export const prepareProviderAuthDocument = (
  harness: ProviderOAuthHarness,
  auth: Record<string, unknown>,
  known: ReadonlyArray<string>
): void => {
  if (harness !== "grok-build") {
    for (const [id, value] of Object.entries(auth)) {
      if (
        typeof value !== "object" ||
        value === null ||
        (value as { type?: unknown }).type !== "oauth" ||
        providerOAuthSupported(harness, id)
      )
        continue
      throw new Error(`${id} uses local OAuth. Use a separate profile for shared accounts.`)
    }
  }
  for (const id of known) {
    const value = auth[id]
    if (
      typeof value === "object" &&
      value !== null &&
      (value as { type?: unknown }).type === "oauth"
    )
      delete auth[id]
  }
}

export const resolvePiResourcePaths = (settings: Record<string, unknown>, source: string): void => {
  for (const key of ["extensions", "skills", "prompts", "themes"]) {
    if (Array.isArray(settings[key]))
      settings[key] = settings[key].map((value) => {
        if (typeof value !== "string") return value
        if (isAbsolute(value) || value.startsWith("~")) return value
        return resolve(source, value)
      })
  }
}
