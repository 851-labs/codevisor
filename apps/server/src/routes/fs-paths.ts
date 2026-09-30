import { homedir } from "node:os"
import { join, resolve } from "node:path"

import { HttpFailure } from "../server-context.js"

/// Expands "~" / "~/…" against the server's home and requires an absolute
/// result — shared by every fs surface so path rules cannot drift.
export const expandFsPath = (requested: string): string => {
  const home = homedir()
  const expanded =
    requested === "~"
      ? home
      : requested.startsWith("~/")
        ? join(home, requested.slice(2))
        : requested
  if (!expanded.startsWith("/")) {
    throw new HttpFailure(400, `Path must be absolute: ${requested}`, "invalid_path")
  }
  return resolve(expanded)
}
