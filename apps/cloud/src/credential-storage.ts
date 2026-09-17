// @boundaries-ignore the Worker bundles the API package from source.
import {
  coordinateCredential,
  type CredentialRecord,
  type CredentialCommand,
  type CredentialCoordinationResult
} from "@codevisor/api"

export const storeCredentialCommand = async (
  storage: DurableObjectStorage,
  deleted: boolean,
  id: string,
  owner: string,
  command: CredentialCommand
): Promise<CredentialCoordinationResult> => {
  if (deleted) return { status: "revoked" }
  return storage.transaction(async (transaction) => {
    const key = `credential:${id}`
    const current = await transaction.get<CredentialRecord>(key)
    const next = coordinateCredential(current, command, owner, Date.now())
    if (next.record !== undefined && JSON.stringify(next.record) !== JSON.stringify(current))
      await transaction.put(key, next.record)
    return next.result
  })
}
const deleteStoredCredentials = async (storage: DurableObjectStorage): Promise<void> => {
  const credentials = await storage.list({ prefix: "credential:" })
  if (credentials.size > 0) await storage.delete([...credentials.keys()])
}

export const deleteHubAccount = async (
  ctx: DurableObjectState,
  closeCode: number
): Promise<void> => {
  await ctx.storage.put("account_deleted", true)
  for (const socket of ctx.getWebSockets()) socket.close(closeCode, "cloud account deleted")
  ctx.storage.sql.exec("DELETE FROM session_buffers; DELETE FROM sessions; DELETE FROM machines")
  await deleteStoredCredentials(ctx.storage)
  await ctx.storage.deleteAlarm()
}
