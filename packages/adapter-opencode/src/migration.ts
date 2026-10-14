import type { OpenCodeServer } from "./server.js"

type MigrationStatus =
  | { readonly status: "required" | "completed" }
  | { readonly status: "running"; readonly progress?: { readonly label?: string } }
  | { readonly status: "error"; readonly error: string }

const STATUS_PATH = "/api/experimental/migration/v1"

export interface OpenCodeMigration {
  readonly finish: () => Promise<void>
}

export interface OpenCodeMigrationDeps {
  readonly start: () => Promise<OpenCodeServer>
  readonly wait?: (ms: number) => Promise<void>
  readonly pollMs?: number
}

export const pendingOpenCodeMigration = async (
  deps: OpenCodeMigrationDeps
): Promise<OpenCodeMigration | undefined> => {
  const wait =
    deps.wait ?? ((ms: number) => new Promise<void>((done) => setTimeout(done, ms).unref()))
  const pollMs = deps.pollMs ?? 1_000
  const server = await deps.start()
  const status = () => server.request<MigrationStatus>(STATUS_PATH)
  let first: MigrationStatus
  try {
    first = await status()
  } catch (cause) {
    await server.stop()
    throw cause
  }
  if (first.status === "completed") {
    await server.stop()
    return undefined
  }
  return {
    finish: async () => {
      try {
        let current = first
        while (current.status !== "completed") {
          if (current.status === "error")
            throw new Error(`OpenCode couldn't migrate its sessions: ${current.error}`)
          await wait(pollMs)
          current = await status()
        }
      } finally {
        await server.stop()
      }
    }
  }
}
