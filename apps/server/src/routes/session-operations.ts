import type { CodevisorServerServices } from "../server-context.js"

const operations = new WeakMap<CodevisorServerServices, Map<string, Promise<void>>>()

export const withSessionMutation = <T>(
  services: CodevisorServerServices,
  sessionId: string,
  operation: () => Promise<T>
): Promise<T> => {
  let pending = operations.get(services)
  if (pending === undefined) {
    pending = new Map()
    operations.set(services, pending)
  }
  const key = sessionId.toLowerCase()
  const result = (pending.get(key) ?? Promise.resolve()).then(operation)
  const tail = result.then(
    () => undefined,
    () => undefined
  )
  pending.set(key, tail)
  return result.finally(() => {
    if (pending.get(key) === tail) pending.delete(key)
  })
}
