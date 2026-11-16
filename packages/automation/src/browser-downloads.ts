import { existsSync, mkdirSync, renameSync } from "node:fs"
import { basename, dirname, join } from "node:path"

export interface BrowserDownload {
  readonly guid: string
  readonly url: string
  readonly suggestedFilename: string
  readonly path?: string
  readonly state?: string
}

export const namedDownloadPath = (downloadsDir: string, download: BrowserDownload): string => {
  const stored = join(downloadsDir, download.guid)
  if (download.path !== undefined && download.path !== stored) return download.path

  const named = join(downloadsDir, "named", download.guid, safeFilename(download.suggestedFilename))
  if (existsSync(named)) return named
  if (!existsSync(stored)) return stored

  mkdirSync(dirname(named), { recursive: true })
  renameSync(stored, named)
  return named
}

const firstPrintableCode = 32

const safeFilename = (suggested: string): string => {
  const name = basename(suggested.replaceAll("\\", "/"))
    .split("")
    .filter((unit) => unit.charCodeAt(0) >= firstPrintableCode)
    .join("")
  if (name === "" || name === "." || name === "..") return "download"
  return name
}
