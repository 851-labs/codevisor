import type { CodevisorServerServices } from "./server-context-types.js"

const queues = new WeakMap<CodevisorServerServices, Map<string, Promise<unknown>>>()

export const withWorktreeLifecycle = async <A>(
  services: CodevisorServerServices,
  key: string,
  operation: () => Promise<A>
): Promise<A> => {
  let pending = queues.get(services)
  if (pending === undefined) {
    pending = new Map()
    queues.set(services, pending)
  }
  const previous = pending.get(key) ?? Promise.resolve()
  const next = previous.catch(() => undefined).then(operation)
  pending.set(key, next)
  try {
    return await next
  } finally {
    if (pending.get(key) === next) pending.delete(key)
  }
}
