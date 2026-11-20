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
      if (error)
        reject(
          new Error(`${binary} ${args.join(" ")} failed: ${stderr || error.message}`, {
            cause: error
          })
        )
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

export async function tryEngineWithin(
  binary: string,
  args: ReadonlyArray<string>,
  timeout: number
): Promise<string | undefined> {
  try {
    return await execEngine(binary, args, { timeout })
  } catch (error) {
    if (timedOut(error)) throw error
    return undefined
  }
}

export interface ResolvedContainerEngine {
  readonly engine: ContainerEngine
  readonly name: string
}

export const containerEngineInstallHint =
  "dev:linux runs its remote machine in a Linux container and found no container engine. " +
  "Install one of: Apple's container (brew install container), OrbStack (brew install orbstack), " +
  "or Docker Desktop, and make sure it is running."

export async function resolveContainerEngine(): Promise<ResolvedContainerEngine> {
  const resolved = (await appleContainerEngine()) ?? (await dockerEngine())
  if (resolved === undefined) throw new Error(containerEngineInstallHint)
  return resolved
}

async function appleContainerEngine(): Promise<ResolvedContainerEngine | undefined> {
  const version = await tryEngine("container", ["--version"])
  if (version === undefined) return undefined
  if (!isSupportedAppleContainer(version)) {
    console.warn(
      `Apple container CLI ${version.trim()} is too old for dev containers; install 1.x: brew install container`
    )
    return undefined
  }
  if ((await tryEngine("container", ["system", "start"])) === undefined) return undefined
  return { engine: "apple", name: "Apple container" }
}

async function dockerEngine(): Promise<ResolvedContainerEngine | undefined> {
  const system = await tryEngine("docker", ["info", "--format", "{{.OperatingSystem}}"])
  if (system === undefined) return undefined
  return { engine: "docker", name: dockerEngineName(system) }
}

export function dockerEngineName(operatingSystem: string): string {
  const reported = operatingSystem.trim()
  if (/orbstack/i.test(reported)) return "OrbStack"
  if (/docker desktop/i.test(reported)) return "Docker Desktop"
  return reported.length > 0 ? `Docker (${reported})` : "Docker"
}

function timedOut(error: unknown): boolean {
  const cause = error instanceof Error ? error.cause : undefined
  return cause instanceof Error && "killed" in cause && cause.killed === true
}

function isSupportedAppleContainer(version: string): boolean {
  const major = /version (\d+)\./.exec(version)?.[1]
  return major !== undefined && Number(major) >= 1
}
