import { execFile } from "node:child_process"
import { mkdir, writeFile } from "node:fs/promises"
import { userInfo } from "node:os"
import { dirname, join } from "node:path"
import { promisify } from "node:util"

import { pathExists } from "./files.ts"

const exec = promisify(execFile)

export const xcodeProjects: Readonly<Record<string, string>> = {
  ios: "apps/ios/Codevisor.xcodeproj",
  macos: "apps/macos/Codevisor.xcodeproj",
  pixelbook: "apps/pixelbook/PixelBook.xcodeproj"
}

export function xcodeDerivedDataLocation(platform: string): string {
  return `../../tmp/build/${platform}/XcodeDerivedData`
}

export async function ensureXcodeDerivedDataSettings(
  repoRoot: string,
  username: string = userInfo().username,
  platform: string = process.platform
): Promise<Array<string>> {
  const written: Array<string> = []
  if (platform !== "darwin") return written

  for (const [name, project] of Object.entries(xcodeProjects)) {
    const projectPath = join(repoRoot, project)
    if (!(await pathExists(projectPath))) continue

    const settingsPath = join(
      projectPath,
      "project.xcworkspace",
      "xcuserdata",
      `${username}.xcuserdatad`,
      "WorkspaceSettings.xcsettings"
    )
    const location = xcodeDerivedDataLocation(name)
    if (await pathExists(settingsPath)) {
      await exec("/usr/bin/plutil", [
        "-replace",
        "DerivedDataLocationStyle",
        "-string",
        "WorkspaceRelativePath",
        settingsPath
      ])
      await exec("/usr/bin/plutil", [
        "-replace",
        "DerivedDataCustomLocation",
        "-string",
        location,
        settingsPath
      ])
    } else {
      await mkdir(dirname(settingsPath), { recursive: true })
      await writeFile(settingsPath, settingsPlist(location))
    }
    written.push(settingsPath)
  }
  return written
}

function settingsPlist(location: string): string {
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
