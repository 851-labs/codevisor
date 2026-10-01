import type { CodevisorDatabaseService } from "@codevisor/db"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import { Effect } from "effect"

const NAMESPACE = "local.shared-accounts"

/** Machine-local sign-in state; credential grants and shared selection live in their own stores. */
export class SharedAccountLocalState {
  private readonly capturingLogins = new Set<string>()

  constructor(
    private readonly db: CodevisorDatabaseService,
    private readonly serverId: string
  ) {}

  async resolveAlias(id: string): Promise<string> {
    const alias = await this.read(`alias:${id}`)
    return typeof alias === "string" ? alias : id
  }

  async hasAlias(id: string): Promise<boolean> {
    return Boolean(await this.read(`alias:${id}`))
  }

  setAlias(id: string, target: string): Promise<void> {
    return this.write(`alias:${id}`, target)
  }

  async isDisabled(id: string): Promise<boolean> {
    return (await this.read(`disabled:${id}`)) === true
  }

  setDisabled(id: string, disabled: boolean): Promise<void> {
    return this.write(`disabled:${id}`, disabled)
  }

  async loginTarget(id: string): Promise<string | undefined> {
    const target = await this.read(`login:${id}`)
    return typeof target === "string" ? target : undefined
  }

  isCapturingLogin(id: string): boolean {
    return this.capturingLogins.has(id)
  }

  async isLoginPending(id: string): Promise<boolean> {
    return (await this.read(`pending:${id}`)) === true
  }

  async prepareLogin(profileId: string, targetId: string): Promise<void> {
    this.capturingLogins.add(profileId)
    await this.write(`login:${profileId}`, targetId)
    await this.write(`pending:${targetId}`, true)
  }

  async completeLogin(profileId: string, targetId: string): Promise<void> {
    this.capturingLogins.delete(profileId)
    await this.write(`pending:${targetId}`, false)
  }

  async cancelLogin(profileId: string): Promise<void> {
    this.capturingLogins.delete(profileId)
    const target = await this.loginTarget(profileId)
    if (target !== undefined) await this.write(`pending:${target}`, false)
  }

  private async read(key: string): Promise<unknown> {
    return (await Effect.runPromise(this.db.getSyncEntries(NAMESPACE))).find(
      (entry) => entry.key === key && !entry.deleted
    )?.value
  }

  private async write(key: string, value: unknown): Promise<void> {
    await Effect.runPromise(
      this.db.mergeSyncEntries(NAMESPACE, [
        {
          key,
          value,
          timestamp: nextSyncTimestamp(
            this.serverId,
            latestSyncTimestamp(await Effect.runPromise(this.db.getSyncEntries(NAMESPACE))),
            Date.now()
          )
        }
      ])
    )
  }
}
