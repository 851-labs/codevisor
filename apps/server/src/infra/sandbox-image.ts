import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import { readdir, readFile } from "node:fs/promises"
import { join } from "node:path"
import { pipeline } from "node:stream/promises"

import { harnessCatalog } from "@codevisor/agent-runtime"
import { installCommand } from "@codevisor/harness-manager"
import type {
  ContainerImageRecipe,
  ContainerImages,
  TartImageRecipe,
  TartImages
} from "@codevisor/sandboxes"

export interface TartImageSettings {
  readonly appPath: string | undefined
  readonly serverIdentityUrl: string
  readonly installUrl?: string
  readonly installEnvironment?: Readonly<Record<string, string>>
  readonly developmentInstance?: string
}

export interface ContainerImageSettings {
  readonly artifactsUrl?: string
}

export const PREINSTALLED_AGENT_IDS = ["claude-code", "codex", "gemini", "amp", "opencode"]
export const STABLE_SERVER_MANIFEST_URL = "https://updates.codevisor.dev/server/stable.json"

const standaloneServerPort = 49361
const linuxServerArchive = "codevisor-server-linux-arm64.tar.gz"

export const tartImages = (
  settings: TartImageSettings,
  fetchText: (url: string) => Promise<string> = fetchBody
): TartImages => ({
  recipe: async () => {
    if (settings.appPath === undefined) return undefined

    return recipeFor(settings.appPath, settings, await fetchText(settings.serverIdentityUrl))
  }
})

export const containerImages = (
  settings: ContainerImageSettings,
  fetchText: (url: string) => Promise<string> = fetchBody
): ContainerImages => ({
  recipe: async () =>
    (await developmentContainerRecipe(settings.artifactsUrl, fetchText)) ??
    (await stableContainerRecipe(fetchText))
})

export const appBundleOf = (executablePath: string): string | undefined => {
  const end = executablePath.indexOf(".app/")
  return end < 0 ? undefined : executablePath.slice(0, end + ".app".length)
}

export const preinstalledAgentCommands = (
  ids: ReadonlyArray<string> = PREINSTALLED_AGENT_IDS
): ReadonlyArray<string> =>
  ids.flatMap((id) => {
    const method = harnessCatalog.find((harness) => harness.id === id)?.installMethods?.[0]
    return method === undefined ? [] : [installCommand(method)]
  })

const recipeFor = async (
  appPath: string,
  settings: TartImageSettings,
  serverIdentity: string
): Promise<TartImageRecipe> => ({
  appPath,
  fingerprint: sha256([await appIdentity(appPath), serverIdentity]),
  agentCommands: preinstalledAgentCommands(),
  ...(settings.installUrl === undefined ? {} : { installUrl: settings.installUrl }),
  ...(settings.installEnvironment === undefined
    ? {}
    : { installEnvironment: settings.installEnvironment }),
  ...(settings.developmentInstance === undefined
    ? {}
    : {
        development: {
          instanceId: settings.developmentInstance,
          serverPort: standaloneServerPort
        }
      })
})

const developmentContainerRecipe = async (
  artifactsUrl: string | undefined,
  fetchText: (url: string) => Promise<string>
): Promise<ContainerImageRecipe | undefined> => {
  if (artifactsUrl === undefined) return undefined
  const identity = await fetchText(`${artifactsUrl}/${linuxServerArchive}.sha256`).catch(
    () => undefined
  )
  if (identity === undefined) return undefined

  return {
    fingerprint: sha256([identity]),
    installUrl: `${artifactsUrl}/install.sh`,
    installEnvironment: { CODEVISOR_SERVER_ARCHIVE_BASE: artifactsUrl, CODEVISOR_VERSION: "dev" }
  }
}

const stableContainerRecipe = async (
  fetchText: (url: string) => Promise<string>
): Promise<ContainerImageRecipe | undefined> => {
  const identity = await fetchText(STABLE_SERVER_MANIFEST_URL).catch(() => undefined)
  return identity === undefined ? undefined : { fingerprint: sha256([identity]) }
}

const appIdentity = async (appPath: string): Promise<string> => {
  const contents = join(appPath, "Contents")
  const signature = await readFile(join(contents, "_CodeSignature", "CodeResources"))
  const executables = await executableStamps(join(contents, "MacOS"))
  return sha256([signature.toString("base64"), ...executables])
}

const executableStamps = async (directory: string): Promise<ReadonlyArray<string>> => {
  const names = (await readdir(directory)).toSorted()
  return Promise.all(
    names.map(async (name) => `${name}:${await fileDigest(join(directory, name))}`)
  )
}

const fileDigest = async (path: string): Promise<string> => {
  const hash = createHash("sha256")
  await pipeline(createReadStream(path), hash)
  return hash.digest("hex")
}

const sha256 = (parts: ReadonlyArray<string>): string =>
  createHash("sha256").update(parts.join("\n")).digest("hex")

const fetchBody = async (url: string): Promise<string> => {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`Could not read ${url} (HTTP ${response.status})`)
  return response.text()
}
