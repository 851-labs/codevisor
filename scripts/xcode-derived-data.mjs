// Points the Xcode app's DerivedData for each project at the worktree's
// ignored tmp/build/, so it is deleted with the worktree instead of piling up
// in ~/Library/Developer/Xcode/DerivedData keyed by a path that no longer
// exists. Command-line builds already pass -derivedDataPath (xcodebuild.mjs);
// this covers Xcode windows (indexing, package resolution, Xcode MCP builds).
//
// Xcode only honors this setting from the per-user workspace settings, not
// from xcshareddata, and xcuserdata/ is ignored, so every checkout writes its
// own. Runs from the post-checkout hook and before scripts open Xcode.
import { execFile } from "node:child_process"
import { access, mkdir, realpath, writeFile } from "node:fs/promises"
import { userInfo } from "node:os"
import { dirname, join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

const exec = promisify(execFile)

export const xcodeProjects = {
  ios: "apps/ios/Codevisor.xcodeproj",
  macos: "apps/macos/Codevisor.xcodeproj",
  pixelbook: "apps/pixelbook/PixelBook.xcodeproj"
}

// Resolved by Xcode relative to the directory containing the .xcodeproj.
// Kept apart from the command-line DerivedData so an Xcode build and a
// scripted build never contend for the same build database.
export function xcodeDerivedDataLocation(platform) {
  return `../../tmp/build/${platform}/XcodeDerivedData`
}

export async function ensureXcodeDerivedDataSettings(repoRoot, username = userInfo().username) {
  const written = []
  // Xcode and plutil exist only on macOS; Linux checkouts (CI) have nothing to configure.
  if (process.platform !== "darwin") return written
  for (const [platform, project] of Object.entries(xcodeProjects)) {
    const projectPath = join(repoRoot, project)
    if (!(await exists(projectPath))) continue
    const settingsPath = join(
      projectPath,
      "project.xcworkspace",
      "xcuserdata",
      `${username}.xcuserdatad`,
      "WorkspaceSettings.xcsettings"
    )
    const location = xcodeDerivedDataLocation(platform)
    if (await exists(settingsPath)) {
      // Preserve any other per-user workspace settings.
      await plutil([
        "-replace",
        "DerivedDataLocationStyle",
        "-string",
        "WorkspaceRelativePath",
        settingsPath
      ])
      await plutil(["-replace", "DerivedDataCustomLocation", "-string", location, settingsPath])
    } else {
      await mkdir(dirname(settingsPath), { recursive: true })
      await writeFile(settingsPath, settingsPlist(location))
    }
    written.push(settingsPath)
  }
  return written
}

function settingsPlist(location) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DerivedDataCustomLocation</key>
	<string>${location}</string>
	<key>DerivedDataLocationStyle</key>
	<string>WorkspaceRelativePath</string>
</dict>
</plist>
`
}

async function plutil(arguments_) {
  await exec("/usr/bin/plutil", arguments_)
}

async function exists(path) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

if (process.argv[1] && (await realpath(process.argv[1])) === fileURLToPath(import.meta.url)) {
  await ensureXcodeDerivedDataSettings(
    process.argv[2] ?? (await realpath(join(dirname(fileURLToPath(import.meta.url)), "..")))
  )
}
