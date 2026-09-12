import { createHash } from "node:crypto"

/** Stable across machines, without sending repository credentials or local paths to Cloud. */
export const pluginConsentKey = (id: string, sourceURL: string, subpath = ""): string =>
  createHash("sha256")
    .update(JSON.stringify([id, sourceURL, subpath]))
    .digest("hex")
