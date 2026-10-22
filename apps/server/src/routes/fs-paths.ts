import { homedir } from "node:os"
import { join, resolve } from "node:path"

import { HttpFailure } from "../server-context.js"

const expandHome = (requested: string, home: string): string => {
  if (requested === "~") return home
  if (requested.startsWith("~/")) return join(home, requested.slice(2))
  return requested
}

export const expandFsPath = (requested: string): string => {
  const home = homedir()
  const expanded = expandHome(requested, home)
  if (!expanded.startsWith("/")) {
    throw new HttpFailure(400, `Path must be absolute: ${requested}`, "invalid_path")
  }
  return resolve(expanded)
}
