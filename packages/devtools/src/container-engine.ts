import { execFile } from "node:child_process"

export type ContainerEngine = "apple" | "docker"

const maxOutputBytes = 16 * 1024 * 1024

export function engineBinary(engine: ContainerEngine): string {
  return engine === "apple" ? "container" : "docker"
}

export function execEngine(
  binary: string,
  args: ReadonlyArray<string>,
  options: { timeout?: number } = {}
): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(binary, args, { maxBuffer: maxOutputBytes, ...options }, (error, stdout, stderr) => {
      if (error) reject(new Error(`${binary} ${args.join(" ")} failed: ${stderr || error.message}`))
      else resolve(stdout)
    })
  })
}

export async function tryEngine(
  binary: string,
  args: ReadonlyArray<string>,
  options?: { timeout?: number }
): Promise<string | undefined> {
  try {
    return await execEngine(binary, args, options)
  } catch {
    return undefined
  }
}

export async function resolveContainerEngine(
  preference?: string,
  environment: Readonly<Record<string, string | undefined>> = process.env
): Promise<ContainerEngine | undefined> {
  const wanted = preference ?? environment.CODEVISOR_DEV_CONTAINER_ENGINE ?? "auto"
  if (wanted === "none") return undefined
  if (wanted === "apple") return appleContainerEngine()
  if (wanted === "docker") return dockerEngine()

  return (await appleContainerEngine()) ?? (await dockerEngine())
}

async function appleContainerEngine(): Promise<ContainerEngine | undefined> {
  const version = await tryEngine("container", ["--version"])
  if (version === undefined) return undefined
  if (!isSupportedAppleContainer(version)) {
    console.warn(
      `Apple container CLI ${version.trim()} is too old for dev containers; install 1.x: brew install container`
    )
    return undefined
  }
  return (await tryEngine("container", ["system", "start"])) === undefined ? undefined : "apple"
}

async function dockerEngine(): Promise<ContainerEngine | undefined> {
  const version = await tryEngine("docker", ["version", "--format", "{{.Server.Version}}"])
  return version === undefined ? undefined : "docker"
}

function isSupportedAppleContainer(version: string): boolean {
  const major = /version (\d+)\./.exec(version)?.[1]
  return major !== undefined && Number(major) >= 1
}
