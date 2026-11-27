import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const ownerOnlyFile = 0o600
const ownerOnlyFolder = 0o700
const systemConfigFolders = "/etc/xdg"
const notStartedInThisDesktop = ["xfce-polkit.desktop"]
const hiddenEntry =
  "[Desktop Entry]\nType=Application\nName=Not started in the Codevisor desktop\nHidden=true\n"

const ownFolder = (runtimeFolder: string): string => join(runtimeFolder, "codevisor-desktop-xdg")

export const removeSessionConfig = (runtimeFolder: string): void => {
  try {
    rmSync(ownFolder(runtimeFolder), { recursive: true, force: true })
  } catch {
    return
  }
}

const freshOwnFolder = (runtimeFolder: string): string | undefined => {
  const folder = ownFolder(runtimeFolder)
  const autostart = join(folder, "autostart")
  try {
    rmSync(folder, { recursive: true, force: true })
    mkdirSync(folder, { mode: ownerOnlyFolder })
    mkdirSync(autostart, { mode: ownerOnlyFolder })
    for (const entry of notStartedInThisDesktop)
      writeFileSync(join(autostart, entry), hiddenEntry, { mode: ownerOnlyFile, flag: "wx" })
    return folder
  } catch {
    return undefined
  }
}

export const sessionConfigFolders = (
  runtimeFolder: string,
  inherited: string | undefined
): string => {
  const systems = inherited === undefined || inherited === "" ? systemConfigFolders : inherited
  const folder = freshOwnFolder(runtimeFolder)
  return folder === undefined ? systems : `${folder}:${systems}`
}
