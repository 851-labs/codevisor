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

export function xcodeDerivedDataLocation(platform) {
  return `../../tmp/build/${platform}/XcodeDerivedData`
}

export async function ensureXcodeDerivedDataSettings(repoRoot, username = userInfo().username) {
  const written = []
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
