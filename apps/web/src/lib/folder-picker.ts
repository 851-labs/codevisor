import { isTauri } from "@tauri-apps/api/core"
import { open } from "@tauri-apps/plugin-dialog"

// Picks a project folder. Inside Tauri this is the native directory picker
// (the webview alone can't produce absolute filesystem paths); in browser dev
// we fall back to asking for a path directly.
export async function pickProjectFolder(): Promise<string | undefined> {
  if (isTauri()) {
    const selection = await open({ directory: true, multiple: false, title: "Add a project" })
    return typeof selection === "string" ? selection : undefined
  }
  const path = window.prompt("Absolute path of the project folder:")
  if (path == null) return undefined
  const trimmed = path.trim()
  return trimmed.startsWith("/") ? trimmed : undefined
}

// A project display name from its folder path (last path component).
export function projectNameFromPath(path: string): string {
  const trimmed = path.replace(/\/+$/, "")
  const lastSegment = trimmed.split("/").at(-1)
  return lastSegment == null || lastSegment === "" ? trimmed : lastSegment
}
