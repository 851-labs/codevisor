import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

export const readJsonStateFile = (path: string): unknown => {
  if (!existsSync(path)) return undefined
  try {
    return JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return undefined
  }
}

export const writeJsonStateFile = (path: string, value: unknown): void => {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  writeFileSync(temporary, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600 })
  renameSync(temporary, path)
}

export const removeJsonStateFile = (path: string): void => {
  rmSync(path, { force: true })
}
