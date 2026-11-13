import { stringField } from "../unknown-values.js"
import type { CliDeps } from "./support.js"

export const isGitMissing = async (deps: CliDeps, port: number): Promise<boolean> => {
  const health = await deps.fetchJson(`${serverUrl(port)}/v1/health`)
  return stringField(health?.body, "git") === "missing"
}

export const explainMissingGit = async (deps: CliDeps, port: number): Promise<void> => {
  for (const line of await installInstructions(deps, port)) deps.error(line)
  deps.error("When Git is installed, run: codevisor auth login")
}

const installInstructions = async (deps: CliDeps, port: number): Promise<ReadonlyArray<string>> => {
  const info = await deps.fetchJson(`${serverUrl(port)}/v1/info`)
  if (stringField(info?.body, "platform") === "darwin") return macInstructions

  return linuxInstructions(deps)
}

const serverUrl = (port: number): string => `http://127.0.0.1:${port}`

const macInstructions: ReadonlyArray<string> = [
  "Codevisor needs Git, and it isn't installed on this Mac.",
  "Install Apple's developer tools, which include Git:",
  "  xcode-select --install",
  "That opens an installer on this Mac's screen."
]

const linuxInstructions = async (deps: CliDeps): Promise<ReadonlyArray<string>> => {
  const install = await linuxInstallCommand(deps)
  if (install === undefined) return [missingOnThisMachine, "Install it with your package manager."]

  return [missingOnThisMachine, "Install it with:", `  ${install}`]
}

const missingOnThisMachine = "Codevisor needs Git, and it isn't installed on this machine."

const linuxInstallCommand = async (deps: CliDeps): Promise<string | undefined> => {
  for (const manager of packageManagers) {
    const probe = await deps.exec(manager.name, ["--version"])
    if (probe.code === 0) return deps.isRoot ? manager.install : `sudo ${manager.install}`
  }
  return undefined
}

interface PackageManager {
  readonly name: string
  readonly install: string
}

const packageManagers: ReadonlyArray<PackageManager> = [
  { name: "apt-get", install: "apt-get install -y git" },
  { name: "dnf", install: "dnf install -y git" },
  { name: "yum", install: "yum install -y git" },
  { name: "pacman", install: "pacman -S --noconfirm git" },
  { name: "zypper", install: "zypper install -y git" },
  { name: "apk", install: "apk add git" }
]
