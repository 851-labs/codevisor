import type { OpenCodeServer } from "./server.js"

/// OpenCode 2 moves OpenCode 1's sessions into its own format the first time
/// one of its servers starts on that data. The migration runs in the
/// background inside that server and only progresses while it stays up:
/// short-lived OpenCode processes each restart it and die before it ends,
/// and OpenCode fails requests against the half-migrated data meanwhile.
/// So a migration is seen through, by one server kept alive until it ends,
/// before OpenCode is used.

type MigrationStatus =
  | { readonly status: "required" | "completed" }
  | { readonly status: "running"; readonly progress?: { readonly label?: string } }
  | { readonly status: "error"; readonly error: string }

const STATUS_PATH = "/api/experimental/migration/v1"

export interface OpenCodeMigration {
  /// Resolves when OpenCode reports the migration complete; rejects with
  /// OpenCode's reason when it fails. Always stops the server.
  readonly finish: () => Promise<void>
}

export interface OpenCodeMigrationDeps {
  /// Starts an OpenCode 2 server on the data to migrate.
  readonly start: () => Promise<OpenCodeServer>
  /// Resolves after `ms`; injected so polling is testable.
  readonly wait?: (ms: number) => Promise<void>
  readonly pollMs?: number
}

/// The migration still to finish on this data, or undefined when there is
/// none (already migrated, or nothing from OpenCode 1).
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
