import { createHash } from "node:crypto"

export const pluginConsentKey = (id: string, sourceURL: string, subpath = ""): string =>
  createHash("sha256")
    .update(JSON.stringify([id, sourceURL, subpath]))
    .digest("hex")
